#include <sourcemod>
#include <sdktools> //for sdk functions like renaming (actually all i use it for...)

#include "dbi.inc" //Database interface include for SQLite

#define PLUGIN_VERSION			"1.2.8"
#define MAXTEAMS				4
#define TEAM_AUTO				0
#define TEAM_SPEC				1
#define TEAM_RED				2
#define TEAM_BLU				3
#define BLU_ASCII				98
#define RED_ASCII				114
#define SPEC_ASCII				115
#define AUTO_ASCII				97

//Setup handles and player arrays
new bool:cw_TeamRestricted[MAXPLAYERS][MAXTEAMS]; //Boolean array containing whether a player has been restricted to a team
new String:clientId[MAXPLAYERS][64]; //Array containing players client index wrt their steamids
new String:cw_Renamed[MAXPLAYERS][MAX_NAME_LENGTH]; //Array containing client's forced names

//cvar handles
new Handle:cwH_restrictedMessage = INVALID_HANDLE;

//Database handle
new Handle:SQLiteDB;

public Plugin:myinfo =
{
	name = "CW Team Restrict & others",
	author = "bladez",
	description = "Bunch of different shit for tf2pug/ozf rvb",
	version = PLUGIN_VERSION,
	url = "http://www.ipgn.com.au"
}

public OnPluginStart()
{
	AddCommandListener(clientJoinTeam, "jointeam"); //Hook the jointeam command
	RegConsoleCmd("cw_banteam", restrictClientTeam); //Command to restrict a team
	RegConsoleCmd("cw_unbanteam", unrestrictClientTeam); //unrestrict team
	RegAdminCmd("cw_forceteam", forceClientTeam, ADMFLAG_RCON, "cw_forceteam <team name> <steamid>"); //forceteam
	RegConsoleCmd("cw_rename", renameClient); //rename client

	cwH_restrictedMessage = CreateConVar("cw_restricted_message", "WE'RE AT WAR, CHUMP. NO TIME FOR FRATERNISING", "What to show the player when they try to join a restricted team", FCVAR_PLUGIN);
	CreateConVar("cw_version", PLUGIN_VERSION,"CW TR Version", FCVAR_PLUGIN|FCVAR_NOTIFY|FCVAR_REPLICATED|FCVAR_DONTRECORD);
	
	//HookEvent("player_changename", playerNameChangeHook, EventHookMode_Pre); //Hook name change event (generic source)
	
	//Load SQL database up!
	Setup_Database(); //Specify handle/create table/etc
}

public OnMapStart()
{
	CreateTimer(180.0, checkPlayerNames, 0, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE); //Check player names every 3 mins
}

public OnClientConnected(client)
{
	//Set client's restricted teams to none upon connect
	for (new i; i < MAXTEAMS; i++)
	{
		cw_TeamRestricted[client][i] = false;
	}
	strcopy(clientId[client], sizeof(clientId[]), "\0"); //set up client's array
	strcopy(cw_Renamed[client], sizeof(cw_Renamed[]), "\0"); //set up client's array
}

public OnClientAuthorized(client, const String:auth[])
{
	strcopy(clientId[client], sizeof(clientId[]), auth); //Put steamid in array!
	decl String:query[128];
	
	new Handle:dataPack = CreateDataPack(); //datapack containing client, to send with the query callback (so we know whotf we're checking)
	WritePackCell(dataPack, client);
	WritePackString(dataPack, auth); //not really needed, but may use in future?
	
	Format(query, sizeof(query), "SELECT team, name FROM player_restrictions WHERE steam_id='%s'", auth); //get player's banned team
	SQL_TQuery(SQLiteDB, GetClientStoredData, query, dataPack, DBPrio_High); //threaded query with high priority (we want this shit done QUICK!)
	
	LogMessage("We have a SteamID! %s Value of clientId[%i]: %s", auth, client, clientId[client]);
	//CloseHandle(dataPack);
}

public OnClientDisconnect(client)
{
	strcopy(clientId[client], sizeof(clientId[]), "\0"); //clear clientId array for client
	strcopy(cw_Renamed[client], sizeof(cw_Renamed[]), "\0");
}

public Action:clientJoinTeam(client, const String:command[], args)
{
	decl String:buffer[10];
	GetCmdArg(1,buffer,sizeof(buffer));
	StripQuotes(buffer);
	TrimString(buffer);
	//IntToString(buffer);
	new team;

	if (strlen(buffer) == 0)
	{	
		ShowActivity(client, "Jointeam buffer is 0, halting");
		return Plugin_Handled;
	}
	
	team = GetTeamIndexFromString(buffer);
	
	if (cw_TeamRestricted[client][team])
	{
		new String:msg[256];
		GetConVarString(cwH_restrictedMessage, msg, sizeof(msg));
		PrintToChat(client, msg);
		
		if (GetClientTeam(client) == 0)
		{
			if (cw_TeamRestricted[client][TEAM_RED])
			{
				//ChangeClientTeam(client, TEAM_BLU);
				AutoAssign(client);
			}
			else
			{
				//ChangeClientTeam(client, TEAM_RED);
				AutoAssign(client);
			}
		}
		
		return Plugin_Handled;
	}
	
	if (team == TEAM_SPEC)
	{
		ChangeClientTeam(client, TEAM_SPEC);
		return Plugin_Handled;
	}

	if (team == TEAM_AUTO)
	{
		if (!AutoAssign(client))
		{
			LogError("AutoAssign(client) failed. No team was assigned.");
		}
		else
		{
			LogMessage("AutoAssign(client) worked, hooray!");
			return Plugin_Handled;
		}
	}

	return Plugin_Continue;
}
//////////////////////////////////////////////////rename/////////////////////////////////////////////
public Action:renameClient(client, args)
{
	if (client != 0)
	{
		ReplyToCommand(client, "YOU DO NOT HAVE PERMISSION");
	}
	if (args < 2) 
	{
		ReplyToCommand(client, "Syntax: cw_rename <name> <steamid> (rename steamid to name)");
		return Plugin_Handled;
	}
	decl String:arg_string[256], String:steamID[64], String:newName[MAX_NAME_LENGTH];
	GetCmdArgString(arg_string, sizeof(arg_string));
	
	new len, total_len;
	
	//get player name, but return error if len is < 0 (i.e not valid?)
	if ((len = BreakString(arg_string, newName, sizeof(newName))) == -1)
	{
		ReplyToCommand(client, "Syntax: cw_rename <name> <steamid>");
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
		setPlayerName(steamID, newName);
		return Plugin_Handled;
	}
	if (IsClientConnected(clientIndex) && !IsFakeClient(clientIndex))
	{
		SetClientInfo(clientIndex, "name", newName);
		setPlayerName(steamID, newName);
		strcopy(cw_Renamed[clientIndex], sizeof(cw_Renamed[]), newName);
	}
	//SetClientInfo(target, "name", g_NewName[target]);
	
	return Plugin_Handled;
}

public Action:unrestrictClientTeam(client, args)
{
	if (client != 0)
	{
		ReplyToCommand(client, "YOU DO NOT HAVE PERMISSION.");
		return Plugin_Handled;
	}
	
	if (args < 2) 
	{
		ReplyToCommand(client, "Syntax: cw_unbanteam <team> <steamid> (unban player from team)");
		return Plugin_Handled;
	}
	
	decl String:arg_string[256], String:team[8], String:steamID[64];
	GetCmdArgString(arg_string, sizeof(arg_string));
	
	new len, total_len;
	
	//Get team, but if unable to get it (i.e. string is empty or something wierd happened), return plugin handled with syntax error
	if ((len = BreakString(arg_string, team, sizeof(team))) == -1)
	{
		ReplyToCommand(client, "Syntax: cw_unbanteam <team> <steamid>");
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
	
	new teamInt = GetTeamIndexFromString(team);
	
	new clientIndex = GetClientIndex(steamID);
	if (!clientIndex)
	{
		//ReplyToCommand(client, "Unable to get clientIndex of STEAMID %s", steamID);
		UnbanIDFromTeam(steamID);
		return Plugin_Handled;
	}
	
	if (cw_TeamRestricted[clientIndex][teamInt])
	{
		cw_TeamRestricted[clientIndex][teamInt] = false;
		UnbanIDFromTeam(steamID);
		LogMessage("%s no longer restricted from %i", steamID, teamInt);
	}
	return Plugin_Handled;
}

public Action:restrictClientTeam(client,args)
{
	if (client != 0)
	{
		ReplyToCommand(client, "YOU DO NOT HAVE PERMISSION.");
		return Plugin_Handled;
	}
	
	if (args < 2) 
	{
		ReplyToCommand(client, "Syntax: cw_banteam <team> <steamid> (ban player from team)");
		return Plugin_Handled;
	}
	
	decl String:arg_string[256], String:team[8], String:steamID[64];
	GetCmdArgString(arg_string, sizeof(arg_string));
	
	new len, total_len;
	
	//Get team, but if unable to get it (i.e. string is empty or something wierd happened), return plugin handled with syntax error
	if ((len = BreakString(arg_string, team, sizeof(team))) == -1)
	{
		ReplyToCommand(client, "Syntax: cw_banteam <team> <steamid>");
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
	
	new teamInt = GetTeamIndexFromString(team);
	
	new clientIndex = GetClientIndex(steamID);
	if (!clientIndex)
	{
		//ReplyToCommand(client, "Unable to get clientIndex of STEAMID %s", steamID);
		//LogMessage("Unable to get clientIndex of STEAMID %s", steamID):
		BanIDFromTeam(steamID, teamInt);
		return Plugin_Handled;
	}

	//if client is not already restricted to specified team
	if (!cw_TeamRestricted[clientIndex][teamInt])
	{
		if (((teamInt == TEAM_BLU) && (cw_TeamRestricted[clientIndex][TEAM_RED])) || ((teamInt == TEAM_RED) && (cw_TeamRestricted[clientIndex][TEAM_BLU])))
		{
			LogError("Cannot lock player out of both teams");
			return Plugin_Handled;
		}
		else
		{
			cw_TeamRestricted[clientIndex][teamInt] = true;
			BanIDFromTeam(steamID, teamInt);
			LogMessage("%s restricted from %i (cw_TeamRestricted[clientIndex][teamInt] = %b)", steamID, teamInt, cw_TeamRestricted[clientIndex][teamInt]);
		}
	}
	else
	{
		return Plugin_Handled;
	}
	
	if (IsClientConnected(clientIndex) && IsClientInGame(clientIndex) && !IsFakeClient(clientIndex) && GetClientTeam(clientIndex) == teamInt)
	{
		if (teamInt == TEAM_BLU)
		{
			if (!cw_TeamRestricted[clientIndex][TEAM_RED])
			{
				ChangeClientTeam(clientIndex, TEAM_RED);
			}
			else
			{
				ChangeClientTeam(clientIndex, TEAM_SPEC);
			}
		}
		else
		{
			if (!cw_TeamRestricted[clientIndex][TEAM_BLU])
			{
				ChangeClientTeam(clientIndex, TEAM_BLU);
			}
			else
			{
				ChangeClientTeam(clientIndex, TEAM_SPEC);
			}
		}
	}
	
	return Plugin_Handled;
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
	
	decl String:arg_string[256], String:team[8], String:steamID[64];
	GetCmdArgString(arg_string, sizeof(arg_string));
	
	new len, total_len;
	
	//Get team, but if unable to get it (i.e. string is empty or something wierd happened), return plugin handled with syntax error
	if ((len = BreakString(arg_string, team, sizeof(team))) == -1)
	{
		ReplyToCommand(client, "Syntax: cw_forcesteam <steamid> <team name>");
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
	
	new teamInt = GetTeamIndexFromString(team);
	//switch case for the team arg, so we can get team name/index, also it's possible to specify red/blue instead of 2/3

	//decl String:name[MAX_NAME_LENGTH];
	//GetClientName(clientIndex, name, sizeof(name));

	ChangeClientTeam(clientIndex, teamInt);
	
	
	return Plugin_Handled;
}

bool:AutoAssign(client) //When a client uses the "Auto-Team" button
{
	new clientTeam = GetClientTeam(client);
	if (cw_TeamRestricted[client][TEAM_RED]) //if red restricted, assign to blue!
	{
		if (clientTeam != TEAM_BLU) //if the client is not already on the blue team, switch them to blue
		{
			ChangeClientTeam(client, TEAM_BLU);
			AssignPlayerClass(client);
		}
		return true;
	}
	else if (cw_TeamRestricted[client][TEAM_BLU]) //if blue restricted, assign to red
	{
		if (clientTeam != TEAM_RED) //if not on red, move to red
		{
			ChangeClientTeam(client, TEAM_RED);
			AssignPlayerClass(client);
		}
		return true;
	}
	else if (!cw_TeamRestricted[client][TEAM_BLU] && !cw_TeamRestricted[client][TEAM_RED])
	{
		new rand = GetRandomInt(2, 3);
		if (clientTeam != rand)
		{
			ChangeClientTeam(client, rand);
			AssignPlayerClass(client);
		}
		return true;
	}
	else
	{
		if (clientTeam != TEAM_SPEC) //if both teams are restricted (wtf?) force to spec
		{
			ChangeClientTeam(client, TEAM_SPEC);
		}
		return true;
	}
}
//Game doesn't accept hooking and modifying of the "player_changename" event apparently...
/*public playerNameChangeHook(Handle:event, const String:name[], bool:dontBroadcast)
{
	//decl client = GetClientOfUserId(GetEventInt(event, "userid")), 
	decl String:oldName[MAX_NAME_LENGTH], String:newName[MAX_NAME_LENGTH];
	GetEventString(event, "oldname", oldName, sizeof(oldName));
	GetEventString(event, "newname", newName, sizeof(newName));
	SetEventString(event, "newname", oldName);
	LogMessage("player name change hook fired old name: %s new name: %s", oldName, newName);
	
	return Plugin_Handled;
}*/
/////////////////////////////////////////////////////////////////////
//SQL Callbacks
/////////////////////////////////////////////////////////////////////

public ErrorCallback(Handle:owner, Handle:hndle, const String:error[], any:data)
{
	if(error[0]) //If the error string has any contents, ERROR!
	{
		LogError("Query error: %s", error);
	}
}
//The callback when a client joins and the query checks for team bans and name matching steamid (need callbacks for threaded queries obv.)
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
	decl clientIndex, bannedTeam, String:steamID[64], String:queryResult[16], String:name[MAX_NAME_LENGTH];
	ResetPack(data); //set pack pos. to 0
	clientIndex = ReadPackCell(data);
	ReadPackString(data, steamID, sizeof(steamID));
	
	if (!IsFakeClient(clientIndex) && !IsClientConnected(clientIndex)) //if the client disconnected while waiting for threaded query to issue callback, return (highly unlikely in ms env)
	{
		return;
	}
	
	if (SQL_FetchRow(hndl)) //if we have results
	{
		if (SQL_GetFieldCount(hndl) > 1)
		{
			SQL_FetchString(hndl, 0, queryResult, sizeof(queryResult)); //get the first result
			bannedTeam = StringToInt(queryResult) //Turn queryResult into usable int
			SQL_FetchString(hndl, 1, name, sizeof(name)); //player's name when !signup was used
		}
		else
		{
			SQL_FetchString(hndl, 0, queryResult, sizeof(queryResult)); //get the first result (in this case, the only result)
			bannedTeam = StringToInt(queryResult) //Turn queryResult into usable int
		}
	}
	else {
		CloseHandle(data);
		return;
	}
	
	if (bannedTeam && bannedTeam != -1)
	{
		cw_TeamRestricted[clientIndex][bannedTeam] = true; //Cache the banned team so we dont repeatedly need sql queries (would cause problems)
		LogMessage("Client %i is banned from team %i", clientIndex, bannedTeam);
	}
	
	if (strlen(name) > 3)
	{
		strcopy(cw_Renamed[clientIndex], sizeof(cw_Renamed[]), name); //cache name
		LogMessage("Client %i has name %s", clientIndex, name);
	}
	CloseHandle(data);
}

public banTeamQueryCallback(Handle:owner, Handle:hndl, const String:error[], any:data)
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
		CloseHandle(data);
		return;
	}
	
	decl teamInt, String:steamID[64], String:queryResult[128], String:query[128];
	ResetPack(data);
	teamInt = ReadPackCell(data);
	ReadPackString(data, steamID, sizeof(steamID));
	
	if (SQL_FetchRow(hndl))
	{
		LogMessage("BAN QUERY HAS A RESULT~~!!! Therefore, SQL_FastQuery to update");
		SQL_FetchString(hndl, 1, queryResult, sizeof(queryResult));
		new bannedTeam = StringToInt(queryResult);
		if (bannedTeam != teamInt)
		{
			Format(query, sizeof(query), "UPDATE player_restrictions SET team='%i' WHERE steam_id='%s'", teamInt, steamID)
			SQL_LockDatabase(SQLiteDB);
			SQL_FastQuery(SQLiteDB, query); //Fast update query, don't worry about results (we already know it exists... (cause of the callback!))
			SQL_UnlockDatabase(SQLiteDB);
		}
	}
	else 
	{
		Format(query, sizeof(query), "INSERT INTO player_restrictions (steam_id, team) VALUES ('%s', '%i')", steamID, teamInt);
		SQL_LockDatabase(SQLiteDB);
		SQL_FastQuery(SQLiteDB, query); //Fast update query, don't worry about results
		SQL_UnlockDatabase(SQLiteDB);
	}
	
	CloseHandle(data);
}
/////////////////////////////////////////////////////////////////////
//Private functions
/////////////////////////////////////////////////////////////////////
GetTeamIndexFromString(const String:team[])
{
	new teamInt;
	switch (team[0])
	{
		case RED_ASCII:
		{
			teamInt = TEAM_RED;
		}
		case BLU_ASCII:
		{
			teamInt = TEAM_BLU;
		}
		case SPEC_ASCII:
		{
			teamInt = TEAM_SPEC;
		}
		case AUTO_ASCII:
		{
			teamInt = TEAM_AUTO;
		}
		case TEAM_BLU:
		{
			teamInt = TEAM_BLU;
		}
		case TEAM_RED:
		{
			teamInt = TEAM_RED;
		}
		case TEAM_SPEC:
		{
			teamInt = TEAM_SPEC;
		}
		default:
		{
			teamInt = StringToInt(team);
		}
	}
	return teamInt;
}

GetClientIndex(const String:auth[])
{
	LogMessage("SteamID supplied to GetClientIndex(): %s", auth);
	new clientIndex;
	for (new i = 1; i <= MaxClients; i++) //Loop through our clientId array until we find a matching steamid. Client number is 'i'
	{
		decl String:clientCheckAuth[64];
		strcopy(clientCheckAuth, sizeof(clientCheckAuth), clientId[i]);
		//LogMessage("Checking index %i STEAMID: %s", i, clientId[i]);
		if (IsClientConnected(i) && StrEqual(clientCheckAuth, auth))
		{
			clientIndex = i;
			break;
		}
	}
	return clientIndex;
}

AssignPlayerClass(clientIndex)
{
	decl String:playerClass[32];
	if (IsClientConnected(clientIndex))
	{
		new rand = GetRandomInt(1, 3);
		switch(rand)
		{
			case 1:
			{
				Format(playerClass, sizeof(playerClass), "scout");
			}
			case 2:
			{
				Format(playerClass, sizeof(playerClass), "soldier");
			}
			case 3:
			{
				Format(playerClass, sizeof(playerClass), "pyro");
			}
		}
		FakeClientCommandEx(clientIndex, "joinclass %s", playerClass);
		LogMessage("Client %i assigned %s", clientIndex, playerClass);
	}
}

UnbanIDFromTeam(const String:auth[])
{
	//Set steamid's banned team to -1 (i.e. unbanned)
	decl String:query[128];
	Format(query, sizeof(query), "UPDATE player_restrictions SET team='-1' WHERE steam_id='%s'", auth); //Assume that well... player already exists if we're unbanning & won't do anything if they dont
	SQL_TQuery(SQLiteDB, ErrorCallback, query);
	LogMessage("Unbanned %s from whatever team", auth);
}

BanIDFromTeam(const String:auth[], teamInt)
{
	//set steamid's banned team to teamInt
	decl String:query[128];
	new Handle:dataPack = CreateDataPack();
	WritePackCell(dataPack, teamInt);
	WritePackString(dataPack, auth);
	
	Format(query, sizeof(query), "SELECT * FROM player_restrictions WHERE steam_id='%s'", auth);
	SQL_TQuery(SQLiteDB, banTeamQueryCallback, query, dataPack, DBPrio_High); //Want results (so we can see if a player is already in the db or not)
	LogMessage("Banned %s from %i", auth, teamInt); //console spew
}

setPlayerName(const String:auth[], const String:name[])
{
	decl String:query[128];
	Format(query, sizeof(query), "UPDATE player_restrictions SET name='%s' WHERE steam_id='%s'", name, auth);
	SQL_TQuery(SQLiteDB, ErrorCallback, query); //Don't care about the results, so use error callback which'll tell us if something went wrong
}

//Timers need public action, but it's still really a private function
public Action:checkPlayerNames(Handle:timer, any:data)
{
	decl String:clientName[MAX_NAME_LENGTH], String:clientNewName[MAX_NAME_LENGTH];
	for (new i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i) && !IsFakeClient(i) && IsClientInGame(i))
		{
			strcopy(clientNewName, sizeof(clientNewName), cw_Renamed[i]);
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
	SQLiteDB = SQLite_UseDatabase("civilwar", error, sizeof(error)); //Use the flatfile sqlite db "civilwar" (located in sourcemod/data/sqlite/)
	if (SQLiteDB == INVALID_HANDLE)
	{
		SetFailState(error);
	}

	//Setup table if it doesn't exist (if using fresh db or w/e)
	SQL_LockDatabase(SQLiteDB);
	SQL_FastQuery(SQLiteDB, "CREATE TABLE IF NOT EXISTS player_restrictions (steam_id TEXT PRIMARY KEY ON CONFLICT REPLACE, team INT, name TEXT);");
	SQL_UnlockDatabase(SQLiteDB);
}