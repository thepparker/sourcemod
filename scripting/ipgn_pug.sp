#include <sourcemod>

#define PLUGIN_VERSION			"1.0.1"
#define TEAM_AUTO				0
#define TEAM_SPEC				1
#define TEAM_RED				2
#define TEAM_BLU				3
#define BLU_ASCII				98
#define RED_ASCII				114
#define SPEC_ASCII				115
#define AUTO_ASCII				97

new String:clientId[MAXPLAYERS+1][64]; //Array containing players client index wrt their steamids

public Plugin:myinfo =
{
	name = "TF2Pug force team",
	author = "bladez",
	description = "Bunch of different shit for tf2pug/ozf rvb",
	version = PLUGIN_VERSION,
	url = "http://www.ipgn.com.au"
}

public OnPluginStart()
{
	RegAdminCmd("cw_forceteam", forceClientTeam, ADMFLAG_RCON, "cw_forceteam <team name> <steamid>"); //forceteam
}

public OnClientAuthorized(client, const String:auth[])
{
	strcopy(clientId[client], sizeof(clientId[]), auth); //Put steamid in array!
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