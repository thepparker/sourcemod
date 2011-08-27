#include <sourcemod>
#include <sdktools>

#include "dbi.inc"

#pragma semicolon 1

#define PLUGIN_VERSION			"1.0.4"
#define TEAM_AUTO				0
#define TEAM_SPEC				1
#define TEAM_RED				2
#define TEAM_BLU				3
#define BLU_ASCII				98
#define RED_ASCII				114
#define SPEC_ASCII				115
#define AUTO_ASCII				97

new String:clientId[MAXPLAYERS+1][64]; //Array containing players client index wrt their steamids
new String:pug_cRenamed[MAXPLAYERS][MAX_NAME_LENGTH]; //Array containing client's forced names

new bool:LateLoaded;

//Database handle
new Handle:SQLiteDB;

public Plugin:myinfo =
{
	name = "TF2Pug force team and rename",
	author = "bladez",
	description = "Bunch of different shit for tf2pug/ozf rvb",
	version = PLUGIN_VERSION,
	url = "http://www.ipgn.com.au"
}

public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
	LateLoaded = late;
	return APLRes_Success;
}

public OnPluginStart()
{
	RegAdminCmd("cw_forceteam", forceClientTeam, ADMFLAG_RCON, "cw_forceteam <team name> <steamid>"); //forceteam
	RegConsoleCmd("cw_rename", renameClient); //rename client
	
	Setup_Database();
	
	if (LateLoaded)
	{
		decl String:auth[64];
		for (new i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i) && !IsFakeClient(i))
			{
				GetClientAuthString(i, auth, sizeof(auth));
				OnClientAuthorized(i, auth);
			}
		}
	}
}

public OnMapStart()
{
	CreateTimer(180.0, checkPlayerNames, 0, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE); //Check player names every 3 mins
}

public OnClientAuthorized(client, const String:auth[])
{
	strcopy(clientId[client], sizeof(clientId[]), auth); //Put steamid in array!
	decl String:query[128];
	
	new Handle:dataPack = CreateDataPack(); //datapack containing client, to send with the query callback (so we know whotf we're checking)
	WritePackCell(dataPack, client);
	WritePackString(dataPack, auth); //not really needed, but may use in future?
	
	Format(query, sizeof(query), "SELECT name FROM player_alias WHERE steam_id='%s'", auth); //get player's banned team
	SQL_TQuery(SQLiteDB, GetClientStoredData, query, dataPack, DBPrio_High); //threaded query with high priority (we want this shit done QUICK!)
}

public OnClientDisconnect(client)
{
	strcopy(clientId[client], sizeof(clientId[]), "\0"); //clear clientId array for client
	strcopy(pug_cRenamed[client], sizeof(pug_cRenamed[]), "\0");
}

public Action:forceClientTeam(client,args)
{
	if (client != 0)
	{
		ReplyToCommand(client, "YOU DO NOT HAVE PERMISSION. RCON ONLY");
		return Plugin_Handled;
	}
	
	if (args < 2) 
	{
		ReplyToCommand(client, "Syntax: cw_forceteam <team name> <steamid>");
		return Plugin_Handled;
	}
	
	decl String:arg_string[256], String:team[8], String:steamID[64], String:teamName[32];
	GetCmdArgString(arg_string, sizeof(arg_string));
	
	new len, total_len;
	
	//Get team, but if unable to get it (i.e. string is empty or something wierd happened), return plugin handled with syntax error
	if ((len = BreakString(arg_string, team, sizeof(team))) == -1)
	{
		ReplyToCommand(client, "Syntax: cw_forceteam <steamid> <team name>");
		return Plugin_Handled;
	}
	total_len += len;
	
	//Get steamID
	if ((len = BreakString(arg_string[total_len], steamID, sizeof(steamID))) != -1)
	{
		total_len += len;
	}
	else //fuck knows what this else thing does. sets the first char of arg_string to 0 but wat does that do?
	{
		total_len = 0;
		arg_string[0] = '\0';
	}
	
	new clientIndex = GetClientIndex(steamID);
	
	if (!clientIndex)
	{
		//ReplyToCommand(client, "Unable to get clientIndex of STEAMID %s", steamID);
		return Plugin_Handled;
	}
	
	new teamInt;
	//switch case for the team arg, so we can get team name/index, also it's possible to specify red/blue instead of 2/3
	switch (team[0])
	{
		case RED_ASCII:
		{
			teamInt = TEAM_RED;
			Format(teamName, sizeof(teamName), "RED");
		}
		case BLU_ASCII:
		{
			teamInt = TEAM_BLU;
			Format(teamName, sizeof(teamName), "BLU");
		}
		case TEAM_BLU:
		{
			teamInt = TEAM_BLU;
			Format(teamName, sizeof(teamName), "BLU");
		}
		case TEAM_RED:
		{
			teamInt = TEAM_RED;
			Format(teamName, sizeof(teamName), "RED");
		}
		default:
		{
			teamInt = StringToInt(team);
		}
	}

	//decl String:name[MAX_NAME_LENGTH];
	//GetClientName(clientIndex, name, sizeof(name));
	if (IsClientConnected(clientIndex) && !IsFakeClient(clientIndex) && IsClientInGame(clientIndex))
	{
		if (GetClientTeam(clientIndex) != teamInt)
		{
			ChangeClientTeam(clientIndex, teamInt);
		}
	}
	//PrintToChat(clientIndex, "Forced to the %s team", teamName);
	
	return Plugin_Handled;
}

//////////////////////////////////////////////////rename/////////////////////////////////////////////
public Action:renameClient(client, args)
{
	if (client != 0)
	{
		ReplyToCommand(client, "YOU DO NOT HAVE PERMISSION");
	}

	decl String:arg_string[256], String:steamID[64], String:newName[MAX_NAME_LENGTH];
	GetCmdArgString(arg_string, sizeof(arg_string));
	
	new len, total_len;
	
	//get player name, but return error if len is < 0 (i.e not valid?)
	if ((len = BreakString(arg_string, newName, sizeof(newName))) == -1)
	{
		//ReplyToCommand(client, "Syntax: cw_rename <name> <steamid>");
		return Plugin_Handled;
	}
	total_len += len;
	
	//Get steamID
	if ((len = BreakString(arg_string[total_len], steamID, sizeof(steamID))) != -1)
	{
		total_len += len;
	}
	else //fuck knows what this else thing does. sets the first char of arg_string to 0 but wat does that do?
	{
		total_len = 0;
		arg_string[0] = '\0';
	}
	
	if ((strlen(steamID) < 7) || (strlen(newName) > MAX_NAME_LENGTH))
	{
		return Plugin_Handled;
	}
	
	new clientIndex = GetClientIndex(steamID);
	if (!clientIndex)
	{
		//ReplyToCommand(client, "Unable to get clientIndex of STEAMID %s", steamID);
		setPlayerName(steamID, newName);
		return Plugin_Handled;
	}
	if (IsClientConnected(clientIndex) && !IsFakeClient(clientIndex))
	{
		SetClientInfo(clientIndex, "name", newName);
		setPlayerName(steamID, newName);
		strcopy(pug_cRenamed[clientIndex], sizeof(pug_cRenamed[]), newName);
	}
	//SetClientInfo(target, "name", g_NewName[target]);
	
	return Plugin_Handled;
}

//SQL Query callbacks
//general callback
public queryErrorCallback(Handle:owner, Handle:hndle, const String:error[], any:data)
{
	if(error[0]) //If the error string has any contents, ERROR!
	{
		LogError("Query error: %s", error);
	}
}

//when a client joins
public GetClientStoredData(Handle:owner, Handle:hndl, const String:error[], any:data)
{
	if (hndl == INVALID_HANDLE) //no result, die
	{
		LogError("SQL Query failed: %s", error);
		CloseHandle(data);
		return;
	}
	if (error[0]) //Error with query ESCAPE!
	{
		LogError("Query error: %s", error);
		return;
	}
	decl clientIndex, String:steamID[64], String:name[MAX_NAME_LENGTH];
	ResetPack(data); //set pack pos. to 0
	clientIndex = ReadPackCell(data);
	ReadPackString(data, steamID, sizeof(steamID));
	
	if (!IsFakeClient(clientIndex) && !IsClientConnected(clientIndex)) //if the client disconnected while waiting for threaded query to issue callback, return (highly unlikely in ms env)
	{
		return;
	}
	
	if (SQL_FetchRow(hndl)) //if we have results
	{
		SQL_FetchString(hndl, 0, name, sizeof(name)); //player's name when !signup was used
	}
	else {
		CloseHandle(data);
		return;
	}
	
	if (strlen(name) > 3)
	{
		strcopy(pug_cRenamed[clientIndex], sizeof(pug_cRenamed[]), name); //cache name
		LogMessage("Client %i has name %s", clientIndex, name);
	}
	CloseHandle(data);
}

//private functions
GetClientIndex(const String:auth[])
{
	LogMessage("SteamID supplied to GetClientIndex(): %s", auth);
	new clientIndex;
	for (new i = 1; i < MaxClients; i++) //Loop through our clientId array until we find a matching steamid. Client number is 'i'
	{
		//LogMessage("Checking index %i STEAMID: %s", i, clientId[i]);
		if ((IsClientConnected(i)) && (StrEqual(clientId[i], auth)))
		{
			clientIndex = i;
			break;
		}
	}
	return clientIndex;
}

setPlayerName(const String:auth[], const String:name[])
{
	decl String:query[128];
	Format(query, sizeof(query), "INSERT OR REPLACE INTO player_alias (steam_id, name) VALUES ('%s', '%s')", auth, name);
	SQL_TQuery(SQLiteDB, queryErrorCallback, query); //Don't care about the results, so use error callback which'll tell us if something went wrong
}

//Timers need public action, but it's still really a private function
public Action:checkPlayerNames(Handle:timer, any:data)
{
	decl String:clientName[MAX_NAME_LENGTH], String:clientNewName[MAX_NAME_LENGTH];
	for (new i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i) && !IsFakeClient(i) && IsClientInGame(i))
		{
			strcopy(clientNewName, sizeof(clientNewName), pug_cRenamed[i]);
			GetClientName(i, clientName, sizeof(clientName));
			if ((strlen(clientNewName) > 3) && (!StrEqual(clientNewName, clientName)))
			{
				SetClientInfo(i, "name", clientNewName);
			}
		}
	}
}

Setup_Database()
{
	decl String:error[256];
	SQLiteDB = SQLite_UseDatabase("ipgn_pug", error, sizeof(error)); //Use the flatfile sqlite db "civilwar" (located in sourcemod/data/sqlite/)
	if (SQLiteDB == INVALID_HANDLE)
	{
		SetFailState(error);
	}

	//Setup table if it doesn't exist (if using fresh db or w/e)
	SQL_LockDatabase(SQLiteDB);
	SQL_FastQuery(SQLiteDB, "CREATE TABLE IF NOT EXISTS player_alias (steam_id TEXT PRIMARY KEY ON CONFLICT REPLACE, name TEXT);");
	SQL_UnlockDatabase(SQLiteDB);
}