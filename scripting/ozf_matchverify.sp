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
//DEFINES
//----------------

#define PLUGIN_NAME         "ozfortress steam id verifier"
#define PLUGIN_AUTHOR       "jim bob joe"
#define PLUGIN_DESC         "Verifies SteamIDs of players in the server to ensure that only the \
                             correct players are playing"
#define PLUGIN_VERSION      "1.0.1"
#define PLUGIN_URL          "http://asdf.com"

#define TEAM_RED 2
#define TEAM_BLUE 3

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

new String:cAuthArray[MAXPLAYERS+1][64]; //contains steamid wrt client index


new bEnabled = 1;


//----------------
//HANDLES
//----------------
new Handle:g_hMVEnabled = INVALID_HANDLE;
new Handle:g_hMVApiKey = INVALID_HANDLE;
new Handle:g_hMVDebug = INVALID_HANDLE;

//new Handle:g_hClientIDTrie = INVALID_HANDLE; //this trie will hold userids and steamids
new Handle:g_hClanIDTrie = INVALID_HANDLE; //this trie will hold clan ids wrt to steamid
new Handle:g_hClanNameTrie = INVALID_HANDLE; //this trie will hold clan names wrt to clan id, will keep this persistent to avoid excess querying
new Handle:g_hClientVerified = INVALID_HANDLE; //this trie will hold clan id or 0 wrt to steamid depending on whether a client has been verified or not

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
    
    //g_hClientIDTrie = CreateTrie();
    g_hClanIDTrie = CreateTrie();
    g_hClanNameTrie = CreateTrie();
    g_hClientVerified = CreateTrie();
    
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
    
        /*decl String:buf[16];
        new cUserID = GetClientUserId(client);
        Format(buf, sizeof(buf), "%d", cUserID);
        SetTrieString(g_hClientIDTrie, buf, auth, true);*/
    
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
        curl_easy_setopt_int_array(idGET, CURL_Default_Options, sizeof(CURL_Default_Options));
        
        new Handle:dataPack = CreateDataPack();
        WritePackString(dataPack, auth);
        
        curl_easy_setopt_function(idGET, CURLOPT_WRITEFUNCTION, parseClanID, dataPack);
        
        decl String:cidURL[256], String:apiAuthKey[64];
        
        GetConVarString(g_hMVApiKey, apiAuthKey, sizeof(apiAuthKey));
        
        Format(cidURL, sizeof(cidURL), "http://ozfortress.com/serverdata.php?key=%s&do=checkid&steamID=%s",
                                    apiAuthKey,
                                    auth);
        
        curl_easy_setopt_string(idGET, CURLOPT_URL, cidURL);
        
        curl_easy_perform_thread(idGET, curlErrorCheck);
        
        debugMessage("Getting clan IDs for client %s", auth);
    }
}


public parseClanID(Handle:hndl, const String:buffer[], const bytes, const nMemB, any:data)
{
    if (!StrEqual(buffer, "unknown"))
    {
        decl String:auth[64];
        ResetPack(data);
        ReadPackString(data, auth, sizeof(auth));

        debugMessage("cURL returned string \"%s\" for client with steamID %s", buffer, auth);
        
        SetTrieString(g_hClanIDTrie, auth, buffer, true);
        
        getClanNames(buffer);
        
        CloseHandle(data);
    }
    return bytes*nMemB;
}

public curlErrorCheck(Handle:hndl, CURLcode:errorCode, any:data)
{
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
                    curl_easy_setopt_int_array(clanNameGET, CURL_Default_Options, sizeof(CURL_Default_Options));
                    
                    new Handle:dataPack = CreateDataPack();
                    WritePackString(dataPack, cId);
                    
                    curl_easy_setopt_function(clanNameGET, CURLOPT_WRITEFUNCTION, parseClanName, dataPack);
                    
                    Format(cnURL, sizeof(cnURL), "http://ozfortress.com/serverdata.php?key=%s&do=getclanshortname&clanid=%d",
                                                apiAuthKey,
                                                StringToInt(cId));
                    
                    curl_easy_setopt_string(clanNameGET, CURLOPT_URL, cnURL);
                    
                    curl_easy_perform_thread(clanNameGET, curlErrorCheck);
                    
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
    if (!StrEqual(buffer, "unknown"))
    {
        decl String:clanID[16];
        ResetPack(data);
        ReadPackString(data, clanID, sizeof(clanID));
        
        debugMessage("Got clan name %s for clan id %s", buffer, clanID);
        
        SetTrieString(g_hClanNameTrie, clanID, buffer, true);
        
        CloseHandle(data);
    }
    return bytes*nMemB;
}

verifyClients()
{
    new Handle:clanIdReturn = CreateDataPack();
    getClansPlaying(clanIdReturn);
    
    new playerCount = ReadPackCell(clanIdReturn);
    new redClanId = ReadPackCell(clanIdReturn); //according to packing order, red is first. 1 cell is 1 int in size
    new blueClanId = ReadPackCell(clanIdReturn);
    
    debugMessage("CLAN IDS RETURNED: %d, %d", redClanId, blueClanId);
    
    new bool:bReportInvalid = true;
    
    if (playerCount < 7) //less than 7 players in high clans, therefore not official match
    {
        bReportInvalid = false; //don't worry about invalid players
    }
    
    if (blueClanId && redClanId) //make sure we have 2 clan ids
    //if (redClanId) //debug
    {
        decl String:redClan[16], String:blueClan[16], String:auth[64], String:clanId[16], String:clanIdList[512], String:clanArray[16][64];
        IntToString(redClanId, redClan, sizeof(redClan));
        IntToString(blueClanId, blueClan, sizeof(blueClan));
        
        decl junk, numID;
        new bool:bClientLegit;
        
        for (new i = 1; i <= MaxClients; i++)
        {
            if (IsClientConnected(i) && IsClientInGame(i) && !IsFakeClient(i))
            {
                strcopy(auth, sizeof(auth), cAuthArray[i]);
                
                if (!GetTrieValue(g_hClientVerified, auth, junk))
                {
                    if (GetTrieString(g_hClanIDTrie, auth, clanIdList, sizeof(clanIdList)))
                    {
                        if ((numID =  ExplodeString(clanIdList, ",", clanArray, 17, sizeof(clanArray[]))) > 0)
                        {
                            bClientLegit = false;
                            for (new j = 0; j < numID; j++)
                            {
                                strcopy(clanId, sizeof(clanId), clanArray[j]);
                                
                                if (StrEqual(redClan, clanId) || StrEqual(blueClan, clanId)) //in red or blue team, doesn't matter
                                {
                                    bClientLegit = true;
                                    new tmpInt = StringToInt(clanId);
                                    debugMessage("Client %d (%s) verified. Belongs to clan %d", i, auth, tmpInt);
                                    SetTrieValue(g_hClientVerified, auth, tmpInt);
                                }
                            }
                            
                            if (!bClientLegit)
                            {
                                debugMessage("Client %d (%s) is not registered with the red or blue teams", i, auth);
                                if (bReportInvalid)
                                    reportInvalidPlayer(auth);
                            }
                            //reportInvalidPlayer(auth);
                        }
                    }
                }
            }
        }
    }
}

getClansPlaying(Handle:hndl)
{
    decl String:auth[64], String:clanArray[16][64], String:clanIdList[128], String:clanId[16], String:clanName[64];
    
    decl numID, clanValue;
    
    new Handle:redClanArray = CreateArray(32); //hold clan ids for the index array based on indexes i.e redClanArray[0]->clanId, redClanIdIndex[clanId]->clanValue
    new Handle:redClanIdIndex = CreateTrie();
    
    new Handle:blueClanArray = CreateArray(32);
    new Handle:blueClanIdIndex = CreateTrie();
    
    for (new i = 1; i <= MaxClients; i++)
    {
        if (IsClientConnected(i) && IsClientInGame(i) && !IsFakeClient(i))
        {
            strcopy(auth, sizeof(auth), cAuthArray[i]);
            
            if (GetTrieString(g_hClanIDTrie, auth, clanIdList, sizeof(clanIdList)))
            {
                if ((numID =  ExplodeString(clanIdList, ",", clanArray, 17, sizeof(clanArray[]))) > 0)
                {
                    switch (GetClientTeam(i))
                    {
                        case TEAM_RED:
                        {
                            for (new j = 0; j < numID; j++)
                            {
                                strcopy(clanId, sizeof(clanId), clanArray[j]);
                                if (!GetTrieValue(redClanIdIndex, clanId, clanValue))
                                {
                                    PushArrayString(redClanArray, clanId);
                                    SetTrieValue(redClanIdIndex, clanId, 1);
                                }
                                else
                                {
                                    SetTrieValue(redClanIdIndex, clanId, clanValue + 1);
                                }
                            }
                        }
                        case TEAM_BLUE:
                        {
                            for (new j = 0; j < numID; j++)
                            {
                                strcopy(clanId, sizeof(clanId), clanArray[j]);
                                if (!GetTrieValue(blueClanIdIndex, clanId, clanValue))
                                {
                                    PushArrayString(blueClanArray, clanId);
                                    SetTrieValue(blueClanIdIndex, clanId, 1);
                                }
                                else
                                {
                                    SetTrieValue(redClanIdIndex, clanId, clanValue + 1);
                                }
                            }
                        }
                        default:
                        {
                            continue;
                        }
                    }
                    
                    if (GetTrieString(g_hClanNameTrie, clanId, clanName, sizeof(clanName)))
                    {
                        debugMessage("Client %s has clan id %s named %s", auth, clanId, clanName);
                    }
                }
                else
                {
                    debugMessage("Invalid list of clan ids stored for %s - %s", auth, clanIdList);
                }
            }
        }
    }
    
    new redCount, blueCount, redClanId, blueClanId, curCount;
    decl String:tmp[32];

    for (new i = 0; i < GetArraySize(redClanArray); i++)
    {
        GetArrayString(redClanArray, i, tmp, sizeof(tmp)); //will be a clan id as a string
    
        GetTrieValue(redClanIdIndex, tmp, curCount);
        
        debugMessage("Red clan id %s has weighting of %d", tmp, curCount);
        
        if (curCount > redCount)
        {        
            redCount = curCount;
            redClanId = StringToInt(tmp);
        }
    }
    
    for (new i = 0; i < GetArraySize(blueClanArray); i++)
    {
        GetArrayString(blueClanArray, i, tmp, sizeof(tmp));
        
        GetTrieValue(blueClanIdIndex, tmp, curCount);              
        
        debugMessage("Blue clan id %s has weighting of %d", tmp, curCount);
        
        if (curCount > blueCount)
        {        
            blueCount = curCount;
            blueClanId = StringToInt(tmp);
        }
    }
    
    debugMessage("Red count: %d for %d. Blue count: %d for %d", redCount, redClanId,
                                                                blueCount, blueClanId);
    
    debugMessage("Two teams playing are: %d and %d", redClanId, blueClanId);
    
    CloseHandle(redClanArray);
    CloseHandle(redClanIdIndex);
    CloseHandle(blueClanArray);
    CloseHandle(blueClanIdIndex);
    
    WritePackCell(hndl, redCount + blueCount);
    WritePackCell(hndl, redClanId);
    WritePackCell(hndl, blueClanId);
    ResetPack(hndl);
    return;
}

/*reporting invalid players to IRC*/
reportInvalidPlayer(const String:auth[])
{
    debugMessage("Reporting player %s for invalid ID", auth);
    
    new Handle:reportCURL = curl_easy_init();
    if (reportCURL != INVALID_HANDLE)
    {
        //210.50.4.5:6002
        decl String:reportServerIP[64];
        Format(reportServerIP, sizeof(reportServerIP), "udp://210.50.4.5");
        
        new reportServerPort = 6002;
        
        new Handle:dataPack = CreateDataPack();
        WritePackString(dataPack, auth);
        ResetPack(dataPack);
        
        curl_easy_setopt_int_array(reportCURL, CURL_Default_Options, sizeof(CURL_Default_Options));
        
        curl_easy_setopt_string(reportCURL, CURLOPT_URL, reportServerIP);
        curl_easy_setopt_int(reportCURL, CURLOPT_PORT, reportServerPort);
        
        curl_easy_setopt_int(reportCURL, CURLOPT_CONNECT_ONLY, 1);
        
        curl_easy_perform_thread(reportCURL, reportServerConnectCallback, dataPack);
    }
}

public SendRecv_Act:reportSendCallback(Handle:hndl, CURLcode:code, const last_sent_dataSize)
{
    debugMessage("Sending callback hit");
    return SendRecv_Act_GOTO_RECV;
}

public SendRecv_Act:reportReceiveCallback(Handle:hndl, CURLcode:code, const String:receiveData[], const dataSize)
{
    debugMessage("data receive callback");
    return SendRecv_Act_GOTO_END;
}

public reportSARCompleteCallback(Handle:hndl, CURLcode:code)
{
    debugMessage("socket closing");
    CloseHandle(hndl); //hndl is the handle of our curl connection
}

public reportServerConnectCallback(Handle:hndl, CURLcode:code, any:data)
{
    debugMessage("connect callback reached");
    decl String:auth[64];
    ReadPackString(data, auth, sizeof(auth));
    
    if (code == CURLE_OK)
    {
        curl_easy_send_recv(hndl, reportSendCallback, reportReceiveCallback, reportSARCompleteCallback, SendRecv_Act_GOTO_WAIT, 0, 0);
        
        decl String:tmp[128];
        Format(tmp, sizeof(tmp), "INVALID_ID%%%s", auth);
        
        curl_set_send_buffer(hndl, tmp, sizeof(tmp));
        curl_send_recv_Signal(hndl, SendRecv_Act_GOTO_SEND);
        debugMessage("Attempting to send data %s", tmp);
    }
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
        LogMessage("OZF VERIFIER: %s", buf);
    }
}