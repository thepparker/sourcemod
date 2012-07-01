/**
 * Plugin to verify SteamIDs for ozfortress competitions

 */

//----------------
//INCLUDES 
//----------------
#include <sourcemod>
#include <cURL>

//----------------
//COMPILER OPTIONS
//----------------

#pragma semicolon 1 //require semicolons at the end of the line
#pragma dynamic 32767 // NFI what this does, but without it the server will crash!

//----------------
//MACROS
//----------------

#define PLUGIN_NAME         "ozfortress steam id verifier"
#define PLUGIN_AUTHOR       "jim bob joe"
#define PLUGIN_DESC         "Verifies SteamIDs of players in the server to ensure that only the \
                             correct players are playing"
#define PLUGIN_VERSION      "1.0.0"
#define PLUGIN_URL          "http://asdf.com"

#define CURL_DEFAULT_OPTIONS(%1) curl_easy_setopt_int_array(%1, CURL_Default_Options, sizeof(CURL_Default_Options))

//----------------
//GLOBALS
//----------------
new CURL_Default_Options[][2] = {
    { _:CURLOPT_NOSIGNAL, 1},
    { _:CURLOPT_TIMEOUT, 30},
    { _:CURLOPT_CONNECTTIMEOUT, 60 },
    { _:CURLOPT_VERBOSE, 0}
};

new bool:LateLoaded;

new String:cAuthArray[MAXPLAYERS+1][64]; //this array will do something


new bEnabled = 1;


//----------------
//HANDLES
//----------------
new Handle:g_hMVEnabled = INVALID_HANDLE;
new Handle:g_hMVApiKey = INVALID_HANDLE;
new Handle:g_hMVDebug = INVALID_HANDLE;

new Handle:g_hClientIDTrie = INVALID_HANDLE; //this trie will hold userids and steamids
new Handle:g_hClanIDTrie = INVALID_HANDLE; //this trie will hold clan ids wrt to steamid
new Handle:g_hClanNameTrie = INVALID_HANDLE; //this trie will hold clan names wrt to clan id, will keep this persistent to avoid excess querying

//----------------
//INITIALISATION
//----------------
public Plugin:myinfo =
{
    name = PLUGIN_NAME,
    author = PLUGIN_AUTHOR,
    description = PLUGIN_DESC,
    version = PLUGIN_VERSION,
    url = PLUGIN_URL
}

public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
    LateLoaded = late;
    return APLRes_Success;
}

public OnPluginStart()
{
    RegConsoleCmd("mv_verifyid", manualVerifyClients); //manual command for verifying clients
    
    g_hMVEnabled = CreateConVar("mv_enabled", "1", "Enable/disable the Steam ID verification plugin", FCVAR_PROTECTED);
    g_hMVApiKey = CreateConVar("mv_apikey", "test", "The API key for ozfortress.com", FCVAR_PROTECTED|FCVAR_DONTRECORD|FCVAR_UNLOGGED);
    g_hMVDebug = CreateConVar("mv_debug", "1", "Print debug messages to console", FCVAR_PROTECTED);
    
    HookConVarChange(g_hMVEnabled, pluginEnabledHook);
    
    g_hClientIDTrie = CreateTrie();
    g_hClanIDTrie = CreateTrie();
    g_hClanNameTrie = CreateTrie();
    
    if (LateLoaded)
    {
        decl String:auth[64];
        for (new i = 1; i <= MaxClients; i++)
        {
            if (IsClientConnected(i) && !IsFakeClient(i) && IsClientInGame(i))
            {
                GetClientAuthString(i, auth, sizeof(auth));
                OnClientAuthorized(i, auth);
            }
        }
    }
}

//---------------
//CLEANING UP
//---------------


//---------------
//FUNCTIONS
//---------------

//join hook
public OnClientAuthorized(client, const String:auth[])
{
    if (bEnabled)
    {
        strcopy(cAuthArray[client], sizeof(cAuthArray[]), auth);
    
        decl String:buf[16];
        new cUserID = GetClientUserId(client);
        Format(buf, sizeof(buf), "%d", cUserID);
        SetTrieString(g_hClientIDTrie, buf, auth, true);
    
        getClanID(auth);
    }
}

//Convar change hook
public pluginEnabledHook(Handle:cvar, const String:oldValue[], const String:newValue[])
{
    bEnabled = StringToInt(newValue);
    
    switch (bEnabled)
    {
        case 0:
        {
            //should we free the arrays here???
        }
        case 1:
        {
            decl String:auth[64];
            for (new i = 1; i <= MaxClients; i++)
            {
                if (IsClientConnected(i) && !IsFakeClient(i) && IsClientInGame(i))
                {
                    GetClientAuthString(i, auth, sizeof(auth));
                    OnClientAuthorized(i, auth);
                }
            }
        }
        default:
        {
            PrintToServer("Invalid value specified for mv_enabled");
        }
    }
}

//manually verify clients
public Action:manualVerifyClients(client, args)
{
    if (client != 0)
    {
        ReplyToCommand(client, "Invalid permissions");
        return Plugin_Handled;
    }
    if (!bEnabled)
    {
        ReplyToCommand(client, "The match verifying plugin is not enabled. Check mv_enabled");
        return Plugin_Handled;
    }
    
    verifyClients();
    
    return Plugin_Handled;
}

getClanID(const String:auth[])
{
    new Handle:idGET = curl_easy_init();
    
    if (idGET != INVALID_HANDLE)
    {
        CURL_DEFAULT_OPTIONS(idGET);
        
        new Handle:dataPack = CreateDataPack();
        WritePackString(dataPack, auth);
        
        curl_easy_setopt_function(idGET, CURLOPT_WRITEFUNCTION, parseClanID, dataPack);
        
        decl String:cidURL[256], String:apiAuthKey[64];
        
        GetConVarString(g_hMVApiKey, apiAuthKey, sizeof(apiAuthKey));
        
        Format(cidURL, sizeof(cidURL), "http://ozfortress.com/serverdata.php?key=%s&do=checkid&steamID=%s",
                                    apiAuthKey,
                                    auth);
        
        curl_easy_setopt_string(idGET, CURLOPT_URL, cidURL);
        
        curl_easy_perform_thread(idGET, curlErrorCheck, dataPack);
        
        debugMessage("Getting clan IDs for client %s", auth);
    }
}


public parseClanID(Handle:hndl, const String:buffer[], const bytes, const nMemB, any:data)
{
    decl String:auth[64];
    ReadPackString(data, auth, sizeof(auth));

    debugMessage("cURL returned string \"%s\" for client with steamID %s", buffer, auth);
    
    SetTrieString(g_hClanIDTrie, auth, buffer, true);
    
    getClanNames(buffer);
    
    CloseHandle(data);
    
    return bytes*nMemB;
}

public curlErrorCheck(Handle:hndl, CURLcode:errorCode, any:data)
{
    if (data != INVALID_HANDLE)
        CloseHandle(data);

    if (errorCode != CURLE_OK)
    {
        decl String:errorBuff[256];
        curl_easy_strerror(errorCode, errorBuff, sizeof(errorBuff));
        
        debugMessage("ERROR: %s", errorBuff);
    }
}

getClanNames(const String:cID[])
{
    new String:clanArray[16][64];
    decl numID;
    
    if ((numID = ExplodeString(cID, ",", clanArray, 17, sizeof(clanArray[]))) > 0)
    {
        decl String:cnURL[256], String:apiAuthKey[64], String:cId[16], String:cName[64];
        
        GetConVarString(g_hMVApiKey, apiAuthKey, sizeof(apiAuthKey));
        
        for (new i = 0; i < numID; i++)
        {
            strcopy(cId, sizeof(cId), clanArray[i]);
            
            if (!GetTrieString(g_hClanNameTrie, cId, cName, sizeof(cName)))
            {
                new Handle:clanNameGET = curl_easy_init();
                
                if (clanNameGET != INVALID_HANDLE)
                {
                    CURL_DEFAULT_OPTIONS(clanNameGET);
                    
                    new Handle:dataPack = CreateDataPack();
                    WritePackString(dataPack, cId);
                    
                    curl_easy_setopt_function(clanNameGET, CURLOPT_WRITEFUNCTION, parseClanName, dataPack);
                    
                    Format(cnURL, sizeof(cnURL), "http://ozfortress.com/serverdata.php?key=%s&do=getclanshortname&clanid=%d",
                                                apiAuthKey,
                                                StringToInt(cId));
                    
                    curl_easy_setopt_string(clanNameGET, CURLOPT_URL, cnURL);
                    
                    curl_easy_perform_thread(clanNameGET, curlErrorCheck, dataPack);
                    
                    debugMessage("Getting clan name for clan ID %s", cId);
                }
            }
        }
    }
    else
    {
        debugMessage("Invalid string of clan ids returned for %s", cID);
    }
}

public parseClanName(Handle:hndl, const String:buffer[], const bytes, const nMemB, any:data)
{
    //buffer = clan name
    decl String:clanID[16];
    ReadPackString(data, clanID, sizeof(clanID));
    
    debugMessage("Got clan name %s for clan id %s", buffer, clanID);
    
    SetTrieString(g_hClanNameTrie, clanID, buffer, true);
    
    CloseHandle(data);
    
    return bytes*nMemB;
}

verifyClients()
{
    //do stuff
}

//---------------
//STOCKS
//---------------

stock debugMessage(const String:format[], any:...)
{
    decl String:mvdebug[8], String:buf[256];
    GetConVarString(g_hMVDebug, mvdebug, sizeof(mvdebug));
    
    if (StringToInt(mvdebug) == 1)
    {
        VFormat(buf, sizeof(buf), format, 2);
        LogMessage("CURL: %s", buf);
    }
}