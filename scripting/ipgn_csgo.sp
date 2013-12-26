#include <sourcemod>
#include <cstrike>

#pragma semicolon 1

#define PLUGIN_VERSION      "1.0.0"

new String:client_auth_cache[MAXPLAYERS+1][64];
new bool:LateLoaded = false;

public Plugin:myinfo =
{
    name = "iPGN CSGO Helper",
    author = "bladez",
    description = "Provides useful server-side functions for the iPGN CSGO channels",
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
    RegServerCmd("ipgn_say", ipgnSayCommand, "Wraps say in PrintToChat so it isn't prepended with <Console>");
    RegServerCmd("ipgn_setclantag", ipgnSetClanTagCommand, "Sets a player's clan tag");

    // if we loaded late, populate the cache with valid client auth strings
    if (LateLoaded)
    {
        for (new i = 1; i < MaxClients; i++)
        {
            decl String:auth[64];

            if (IsClientInGame(i) && !IsFakeClient(i) && GetClientAuthString(i, auth, sizeof(auth)))
            {
                OnClientAuthorized(i, auth);
            }
        }
    }
}

public OnClientAuthorized(client, const String:auth[])
{
    strcopy(client_auth_cache[client], sizeof(client_auth_cache[]), auth);
}

public Action:ipgnSayCommand(args)
{
    decl String:msg[256];
    GetCmdArgString(msg, sizeof(msg));

    PrintToChatAll("[iPGN-CSGO]: %s", msg);

    return Plugin_Handled;
}

public Action:ipgnSetClanTagCommand(args)
{
    // usage: ipgn_setclan STEAMID <tag>

    if (args < 2)
    {
        PrintToServer("Usage: ipgn_setclantag <sid> <tag>");

        return Plugin_Handled;
    }

    decl String:arg_string[256], String:steam_id[64], String:tag[16];

    new curr_len = 0, total_len = 0;

    GetCmdArg(1, steam_id, sizeof(steam_id));
    GetCmdArg(2, tag, sizeof(tag));

    LogMessage("Steam ID: %s, tag: %s", steam_id, tag);

    new uindex = GetClientIndex(steam_id);

    if (uindex == -1)
    {
        PrintToServer("No client could be found matching the given SteamID");

        return Plugin_Handled;
    }

    CS_SetClientClanTag(uindex, tag);

    return Plugin_Handled;
}

GetClientIndex(const String:auth[])
{
    //LogMessage("SteamID supplied to GetClientIndex(): %s", auth);
    new clientIndex = -1;

    for (new i = 1; i < MaxClients; i++) //Loop through our clientId array until we find a matching steamid. Client number is 'i'
    {
        if (IsClientConnected(i) && IsClientAuthorized(i) && StrEqual(client_auth_cache[i], auth))
        {
            clientIndex = i;
            break;
        }
    }

    return clientIndex;
}
