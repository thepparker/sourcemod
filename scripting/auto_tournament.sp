#include <sourcemod>
#include "include/nextmap.inc" //include for sourcemod next/set/get map functions

#pragma semicolon 1 //must use semicolon to end lines

#define PLUGIN_VERSION			"1.0.9"

///////////////////////////
//Global vars and handles
///////////////////////////
new bool:gameStarted = false;
new bool:LateLoaded;
//for nextmap shit

new g_MapPos = -1;
new Handle:g_MapList = INVALID_HANDLE;
new g_MapListSerial = -1;



///////////////////////////
//Public forwards
///////////////////////////

public Plugin:myinfo =
{
	name = "Auto Tournament Mode",
	author = "bladez",
	description = "Automatically turn tournament mode on at the end of waiting for players",
	version = PLUGIN_VERSION,
	url = "moimoimoimoimoimoimoi"
};

public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
	LateLoaded = late;
	return APLRes_Success;
}

public OnPluginStart() 
{
	//HookEvent("teamplay_waiting_ends", roundWaitEnd); //Unfired event, but let's leave it here for now
	HookEvent("teamplay_round_start", roundStartHook);
	HookEvent("teamplay_game_over", gameOverHook); //Hook the end game event - fired for win conditions: timelimit/winlimit/maxrounds
	HookEvent("tf_game_over", gameOverHook);  //Same as teamplay_game_over, but fires on windifference and other tf only win conditions
	HookEvent("teamplay_round_win", roundWinHook); //hooks round win, so we can see if we should end it at <5 mins or not
	
	//Nextmap business
	g_MapList = CreateArray(32);
	
	// setup vars
	decl String:currentMap[64];
	GetCurrentMap(currentMap, 64);
	SetNextMap(currentMap);
}

public OnMapStart()
{
	//disable tournament mode and set gamestarted to false incase of manual change or whatever
	if (gameStarted)
	{
		ServerCommand("mp_tournament 0");
		gameStarted = false;
	}
}

//
//	Taken from nextmap.sp included in all sourcemod distributions. 
//
public OnConfigsExecuted()
{
	decl String:lastMap[64], String:currentMap[64];
	GetNextMap(lastMap, sizeof(lastMap));
	GetCurrentMap(currentMap, 64);
	
	//if the admin changed the map manually, return to next map in the list
	if (strcmp(lastMap, currentMap) == 0)
	{
		FindAndSetNextMap();
	}
}




/////////////////////////////////////////////////////////////////////
//Event hooks
/////////////////////////////////////////////////////////////////////

//HookEvent("teamplay_round_start", roundStart);
public roundStartHook(Handle:event, const String:name[], bool:dontBroadcast)
{
	LogMessage("round started");
	//End of waiting for players; enable tournament mode and set ready states to 1
	if (!gameStarted)
	{
		ServerCommand("mp_tournament 1;mp_restartgame 1");
		gameStarted = true;
	}
}

//HookEvent("teamplay_game_over", gameOver);
public gameOverHook(Handle:event, const String:name[], bool:dontBroadcast)
{
	decl String:gameOverReason[32];
	GetEventString(event, "reason", gameOverReason, sizeof(gameOverReason));
	LogMessage("Game over. Reason: %s", gameOverReason);
	if (gameStarted)
	{
		//end of map, changelevel in 10 seconds (same as normal)
		gameStarted = false;
		CreateTimer(10.0, changeMap, 0, TIMER_FLAG_NO_MAPCHANGE);
	}
}
public roundWinHook(Handle:event, const String:name[], bool:dontBroadcast)
{
	LogMessage("round win fired");
	decl roundType, timeLeft;
	roundType = GetEventInt(event, "full_round"); //0 for miniround (ie payload maps), 1 for full round (end of payload and all 5cp maps)
	LogMessage("round type: %d", roundType);
	if (!roundType)
	{
		return;
	}
	if (GetMapTimeLeft(timeLeft))
	{
		if ((timeLeft != 0) && (timeLeft < 300))
		{
			//timeleft is < 5 mins at end of full round, therefore, end the map
			decl bonusRoundTime;
			bonusRoundTime = GetConVarInt(FindConVar("mp_bonusroundtime")) - 3;
			new Float:floatedRoundTime = float(bonusRoundTime);
			LogMessage("end of full round and timelimit < 300, starting ending timer to run in %f", floatedRoundTime);
			//ServerCommand("mp_tournament 0");
			CreateTimer(FloatAbs(floatedRoundTime), endMap, 0, TIMER_FLAG_NO_MAPCHANGE);
		}
	}
}



/////////////////////////////////////////////////////////////////////
//Private functions
/////////////////////////////////////////////////////////////////////
//need public action for a timer, but it's still 'private'
public Action:endMap(Handle:timer, any:data)
{
	LogMessage("end map timer called. firing game over event");
	new Handle:gameOverEvent = CreateEvent("tf_game_over");
	if (gameOverEvent == INVALID_HANDLE)
	{
		return;
	}
	
	SetEventString(gameOverEvent, "reason", "Reached Time Limit");
	FireEvent(gameOverEvent);
}
public Action:changeMap(Handle:timer, any:data)
{
	//data is the map, which is passed when the timer is called
	decl String:nextMap[32];
	if (GetNextMap(nextMap, sizeof(nextMap)))
	{
		LogMessage("changemap timer is a go. next map: %s", nextMap);
		ServerCommand("changelevel %s", nextMap);
	}
	else
	{
		PrintToChatAll("An error has occured and there is no next map detected :O");
	}
}

//
//	Taken from nextmap.sp included in all sourcemod distributions. 
//
FindAndSetNextMap()
{
	//read maplist from mapcyclefile
	if (ReadMapList(g_MapList, 
			g_MapListSerial, 
			"mapcyclefile",
			MAPLIST_FLAG_CLEARARRAY|MAPLIST_FLAG_NO_DEFAULT)
		== INVALID_HANDLE)
	{
		if (g_MapListSerial == -1) //no mapcyclefile found
		{
			LogError("FATAL: Cannot load map cycle. Nextmap not loaded.");
			SetFailState("Mapcycle Not Found");
		}
	}
	
	new mapCount = GetArraySize(g_MapList);
	decl String:mapName[32];
	
	if (g_MapPos == -1)
	{
		decl String:current[64];
		GetCurrentMap(current, 64);

		for (new i = 0; i < mapCount; i++)
		{
			GetArrayString(g_MapList, i, mapName, sizeof(mapName));
			if (strcmp(current, mapName, false) == 0)
			{
				g_MapPos = i;
				break;
			}
		}
		
		if (g_MapPos == -1)
		{
			g_MapPos = 0;
		}
	}
	
	g_MapPos++;
	if (g_MapPos >= mapCount) //if we're at the end of the rotation, return to the first map ie. map array position 0
	{
		g_MapPos = 0;	
	}
 	GetArrayString(g_MapList, g_MapPos, mapName, sizeof(mapName));
	SetNextMap(mapName);
	LogMessage("next map is %s", mapName);
}