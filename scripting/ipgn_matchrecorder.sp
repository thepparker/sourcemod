#include <sourcemod>
#include <socket>


#define RED 0
#define BLU 1
#define TEAM_OFFSET 2
#define DEBUG true

public Plugin:myinfo =
{
	name = "iPGN Match Recorder",
	author = "bladez. Original: carbon",
	description = "Demos are automatically recorded in the tournament mode. Modified to better suit iPGN's booking bot and for player convenience",
	version = "0.4.6",
	url = "moimoimoimoimoimoimoi"
};



//------------------------------------------------------------------------------
// Variables
//------------------------------------------------------------------------------

new bool:teamReadyState[2] = { false, false };
new bool:recordOnRestart = false;
new bool:recording = false;
new String:demoname[128];
new String:log[32];

new String:serverPort[16];
new String:serverIP[64];
new String:socketData[192];
new String:botIP[64];
new botPort;

//Handles for convars
new Handle:ipgn_booker = INVALID_HANDLE; //will contain the name of the person who booked the server
new Handle:ipgn_tournament = INVALID_HANDLE; //will contain the name of the tournament (if applicable)
new Handle:ipgn_botip = INVALID_HANDLE; //ip for bot
new Handle:ipgn_botport = INVALID_HANDLE; //port for bot

//------------------------------------------------------------------------------
// Startup
//------------------------------------------------------------------------------

public OnPluginStart()
{
	// Console command to test socket sending
	RegConsoleCmd("test_sock", Test_SockSend);
	
	// Team status updates
	HookEvent("tournament_stateupdate", TeamStateEvent);

	// Game restart
	HookEvent("teamplay_restart_round", GameRestartEvent);

	// Win conditions met (maxrounds, timelimit)
	HookEvent("teamplay_game_over", GameOverEvent);

	// Win conditions met (windifference)
	HookEvent("tf_game_over", GameOverEvent);
	
	//Hook server message events, see if it's a log on
	//HookEvent("server_message", GameLogEvent);

	// Hook into mp_tournament_restart
	RegServerCmd("mp_tournament_restart", TournamentRestartHook);
	
	//Convars
	ipgn_booker = CreateConVar("mr_ipgnbooker", "ipgn_unbooked", "Name of the person who booked the server",FCVAR_NOTIFY);
	ipgn_tournament = CreateConVar("mr_ipgntournament", "","Tournament name string",FCVAR_NOTIFY);
	ipgn_botip = CreateConVar("mr_ipgnbotip", "1.1.1.1", "IP address for iPGN booking bot",FCVAR_PROTECTED);
	ipgn_botport = CreateConVar("mr_ipgnbotport", "2222", "Port for iPGN booking bot",FCVAR_PROTECTED);
	
	//Setup variables for socket sending
	GetConVarString(FindConVar("ip"), serverIP, sizeof(serverIP));
	IntToString(GetConVarInt(FindConVar("hostport")), serverPort, sizeof(serverPort));
}



//------------------------------------------------------------------------------
// Callbacks
//------------------------------------------------------------------------------

public TeamStateEvent(Handle:event, const String:name[], bool:dontBroadcast)
{
	new team = GetClientTeam(GetEventInt(event, "userid")) - TEAM_OFFSET;
	new bool:nameChange = GetEventBool(event, "namechange");
	new bool:readyState = GetEventBool(event, "readystate");

	if (!nameChange)
	{
		teamReadyState[team] = readyState;

		// If both teams are ready wait for round restart to start recording
		if (teamReadyState[RED] && teamReadyState[BLU])
		{
			recordOnRestart = true;
		}
		else
		{
			recordOnRestart = false;
		}
	}
}

public GameRestartEvent(Handle:event, const String:name[], bool:dontBroadcast)
{
	// Start recording only if both team are in ready state
	if (recordOnRestart)
	{
		StartRecording();
		recordOnRestart = false;
		teamReadyState[RED] = false;
		teamReadyState[BLU] = false;
	}
}

public GameOverEvent(Handle:event, const String:name[], bool:dontBroadcast)
{
	StopRecording();
}

//Event to capture log events
//public GameLogEvent(Handle:event, const String:name[], bool:dontBroadcast)
//{
//	PrintToServer("LOG:");
	//return Plugin_Continue;
//}

public Action:TournamentRestartHook(args)
{
	// If mp_tournament_restart is called, stop recording
	if (recording)
	{
		StopRecording();
	}

	return Plugin_Continue;
}

public OnMapStart()
{
	ResetVariables();

	// Check every 30secs if there are still players on the server
	CreateTimer(30.0, CheckPlayers, 0, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
}

public OnMapEnd()
{
	StopRecording();
}

// Stop recording if there are no players on the server - thanks jasonfrog!
public Action:CheckPlayers(Handle:timer)
{
	if (recording)
	{
		for (new i = 1; i <= MaxClients; i++)
		{
			if (IsClientConnected(i) && !IsFakeClient(i))
			{
				return;
			}
		}

		StopRecording();
	}
}

//------------------------------------------------------------------------------
// Socket Functions
//------------------------------------------------------------------------------

public onSocketConnected(Handle:socket, any:arg)
{
	SocketSend(socket, socketData);
	if (DEBUG) { LogMessage("Sent data '%s' to %s:%d", socketData, botIP, botPort); }
	//SocketDisconnect(socket);
}

public onSocketReceive(Handle:socket, String:receiveData[], const dataSize, any:arg)
{
	LogMessage("Data received: %s", receiveData);
	return 0;
}

public onSocketDisconnect(Handle:socket, any:arg)
{
	CloseHandle(socket);
	if (DEBUG) { LogMessage("Socket disconnected and closed"); }
}

public onSocketSendqueueEmpty(Handle:socket, any:arg) 
{
	SocketDisconnect(socket);
	CloseHandle(socket);
	if (DEBUG) { LogMessage("Send queue is empty. Socket closed"); }
}

public onSocketError(Handle:socket, const errorType, const errorNum, any:arg)
{
	LogError("Connect socket error %d (errno %d)", errorType, errorNum);
	CloseHandle(socket);
}

public sendSocketData(String:msg[])
{
	new Handle:socket = SocketCreate(SOCKET_UDP, onSocketError);
	SocketSetSendqueueEmptyCallback(socket,onSocketSendqueueEmpty);
	GetConVarString(ipgn_botip, botIP, sizeof(botIP));
	botPort = GetConVarInt(ipgn_botport);
	Format(socketData, sizeof(socketData), "%s", msg);
	SocketConnect(socket, onSocketConnected, onSocketReceive, onSocketDisconnect, botIP, botPort);
	if (DEBUG) { LogMessage("Attempted to open socket"); }
}

//Command for testing socket sending
public Action:Test_SockSend(client, args)
{
    if (client == 0) {
		CheckForLogFile();
		decl String:msg[192];
		Format(msg, sizeof(msg), "STOP_RECORD@demo-asdf-12234-4352-56.zip@%s@%s_%s", log, serverIP, serverPort);
		sendSocketData(msg);
	}
}

//------------------------------------------------------------------------------
// Private functions
//------------------------------------------------------------------------------

ResetVariables()
{
	teamReadyState[RED] = false;
	teamReadyState[BLU] = false;
	recordOnRestart = false;
	recording = false;
	demoname = "";
	log = "";
	
	//Clear the tournament string, so scrims and what-not don't get stuck with a "c4c2" tag or w/e
	SetConVarString(ipgn_tournament, "")
}

StartRecording()
{
	if (recording)
	{
		PrintToChatAll("Already recording");
		return;
	}

	// Format the demo demoname
	new String:tournament[16];
	new String:timestamp[32];
	new String:map[32];
	new String:command[128];
	new String:booker[64];
	
	//give strings values
	GetConVarString(ipgn_tournament, tournament, sizeof(tournament));
	GetConVarString(ipgn_booker, booker, sizeof(booker));
	FormatTime(timestamp, sizeof(timestamp), "%a-%Y%m%d-%H%M");
	GetCurrentMap(map, sizeof(map));
	
	ReplaceString(booker, sizeof(booker), " ", "_");
	
	if (strlen(tournament) >= 3) 
	{	//Construct demoname with tournament in it, so it's easy to find ;D
		Format(demoname, sizeof(demoname), "%s-%s-%s.dem", tournament, timestamp, map);
	}
	else {
		//Demoname with just the name of the booker, still easier to find than before
		Format(demoname, sizeof(demoname), "%s-%s-%s.dem", booker, timestamp, map);
	}
	//Construct rcon command to record demo and start new log file
	Format(command, sizeof(command), "tv_record %s; log on", demoname);
	
	//Start recording
	ServerCommand(command);
	
	//Notify users of demoname
	PrintToChatAll("Recording started. Demo: %s", demoname);
	
	decl String:msg[192];
	Format(msg, sizeof(msg), "START_RECORD@%s@holder@%s_%s", demoname, serverIP, serverPort); //Send demoname/serverip to bot
	sendSocketData(msg);
	
	recording = true; //We are now recording!
}

StopRecording()
{
	if (recording)
	{
		// Stop recording
		ServerCommand("tv_stoprecord; log off");

		PrintToChatAll("Recording stopped. Demo: %s", demoname); //Notify players of demoname again

		//Get log file name
		CheckForLogFile();
		
		decl String:msg[192]; 
		Format(msg, sizeof(msg), "STOP_RECORD@%s@%s@%s_%s", demoname, log, serverIP, serverPort); //Send demoname/serverip to bot (again)
		sendSocketData(msg);
		
		recording = false;
	}
}

CheckForLogFile()
{
	decl String:logdatestamp[14];
	decl String:logdir[32];
	GetConVarString(FindConVar("sv_logsdir"), logdir, sizeof(logdir));
	FormatTime(logdatestamp, sizeof(logdatestamp), "%m%d");
	
	for (new i = 0; i < 100; i++)
	{
		//logs_server3/L0722015.log
		decl String:logname[32];
		decl String:logfullpath[64];
		
		if (i < 10)
		{
			Format(logname, sizeof(logname), "L%s00%d.log", logdatestamp, i);
			Format(logfullpath, sizeof(logfullpath), "%s/%s", logdir, logname);
			if (DEBUG) { LogMessage("Log name: %s Path: %s", logname, logfullpath); }
			if (FileExists(logfullpath)) 
			{
				strcopy(log, sizeof(log), logname);
			}
			else 
			{
				if (DEBUG) { LogMessage("Log name is: %s", log); }
				return;
			}
		}
		else 
		{
			Format(logname, sizeof(logname), "L%s0%d.log", logdatestamp, i);
			Format(logfullpath, sizeof(logfullpath), "%s/%s", logdir, logname);
			if (DEBUG) { LogMessage("Log name: %s Path: %s", logname, logfullpath); }
			if (FileExists(logfullpath)) {
				strcopy(log, sizeof(log), logname);
			}
			else {
				if (DEBUG) { LogMessage("Log name is: %s", log); }
				return;
			}
		}
	}
}