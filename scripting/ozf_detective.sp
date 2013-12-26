#pragma semicolon 1

#include <sourcemod>
#include <socket>
#include <colors>

#define CVAR_ARRAY_NAME 0
#define CVAR_ARRAY_MINVALUE 1
#define CVAR_ARRAY_MAXVALUE 2

#define CLIENTCVAR_ARRAY_NAME 0
#define CLIENTCVAR_ARRAY_CLIENT_VALUE 1

public Plugin:myinfo =
{
    name = "ozfortress detective",
    author = "bladez",
    description = "detects",
    version = "1.0",
    url = "http://ozfortress.com"
};

new bool:late_loaded;
new bool:b_player_warned[MAXPLAYERS+1] = {false, ...};

new Handle:h_cvars = INVALID_HANDLE;
new Handle:h_cvar_index = INVALID_HANDLE;
new Handle:h_client_cvars[MAXPLAYERS+1] = {INVALID_HANDLE, ...};
new Handle:h_past_clients = INVALID_HANDLE;
new Handle:ipgn_botip = INVALID_HANDLE;
new Handle:ipgn_botport = INVALID_HANDLE;

public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
    late_loaded = late;
    return APLRes_Success;
}

public OnPluginStart()
{
    h_cvars = CreateArray(64);
    h_cvar_index = CreateTrie();
    h_past_clients = CreateTrie();

    //addCVar("fov_desired", 75.0, 90.0);
    addCVar("r_drawothermodels", 0.0, 2.0);
    addCVar("mat_picmip", -1.0, 4.0);
    addCVar("viewmodel_transparancy", 0.0, 0.0);
    addCVar("mod_test_mesh_not_available", 0.0, 0.0);
    addCVar("mod_test_verts_not_available", 0.0, 0.0);
    addCVar("mod_test_not_available", 0.0, 0.0);

    CreateTimer(120.0, getClientCVarTimer, _, TIMER_REPEAT);

    RegConsoleCmd("gogogadget", gogoGadgetDetective);

    if ((ipgn_botip = FindConVar("mr_ipgnbotip")) == INVALID_HANDLE)
    {
        ipgn_botip = CreateConVar("mr_ipgnbotip", "210.50.4.5", "IP address for iPGN booking bot", FCVAR_PROTECTED);
    }
    if ((ipgn_botport = FindConVar("mr_ipgnbotport")) == INVALID_HANDLE)
    {
        ipgn_botport = CreateConVar("mr_ipgnbotport", "6002", "Port for iPGN booking bot", FCVAR_PROTECTED);
    }

    if (late_loaded)
    {
        checkCVars();
    }
}

public OnPluginEnd()
{
    for (new i = 1; i <= MaxClients; i++)
    {
        if (IsClientConnected(i) && !IsFakeClient(i))
        {
            CloseHandle(h_client_cvars[i]);
            h_client_cvars[i] = INVALID_HANDLE;
        }
    }

    CloseHandle(h_cvars);
    CloseHandle(h_cvar_index);
    CloseHandle(h_past_clients);

    h_cvars = INVALID_HANDLE;
    h_cvar_index = INVALID_HANDLE;
    h_past_clients = INVALID_HANDLE;
    
}

public OnClientDisconnect(client)
{
    //CloseHandle(h_client_cvars[client]);
    decl String:userid[8];

    IntToString(GetClientUserId(client), userid, sizeof(userid));
    SetTrieValue(h_past_clients, userid, h_client_cvars[client]); //copy the client handle to this trie, so the client index array can be reallocated for next user

    h_client_cvars[client] = INVALID_HANDLE;
    b_player_warned[client] = false;
}

public Action:getClientCVarTimer(Handle:timer, any:data)
{
    checkCVars(); 
}

public clientCVarCallback(QueryCookie:cookie, client, ConVarQueryResult:result, const String:cvar_name[], const String:cvar_value[])
{
    if (!IsClientConnected(client))
    {
        return;
    }

    decl String:client_name[64], String:client_auth[64], String:client_ip[64], String:client_report[256];
    GetClientName(client, client_name, sizeof(client_name));
    GetClientAuthString(client, client_auth, sizeof(client_auth));
    GetClientIP(client, client_ip, sizeof(client_ip));

    LogMessage("%s (%s) @ %s has CVAR %s value: %s", client_name, client_auth, client_ip, cvar_name, cvar_value);

    new cvar_index;
    if (!GetTrieValue(h_cvar_index, cvar_name, cvar_index))
    {
        LogError("Couldn't find cvar in index");

        return;
    }

    new Handle:h_cvar_array = GetArrayCell(h_cvars, cvar_index), Handle:h_client_trie = h_client_cvars[client];
    new bool:b_report = false, bool:b_new_client = false, bool:b_cvar_high = false;

    new Float:cvar_lower_bound = GetArrayCell(h_cvar_array, CVAR_ARRAY_MINVALUE);
    new Float:cvar_upper_bound = GetArrayCell(h_cvar_array, CVAR_ARRAY_MAXVALUE);
    new cvar_int = StringToInt(cvar_value), client_prev_value;

    if (h_client_trie == INVALID_HANDLE)
    {
        decl String:userid[8];
        IntToString(GetClientUserId(client), userid, sizeof(userid));

        if (h_past_clients == INVALID_HANDLE)
        {
            h_past_clients = CreateTrie();
        }

        if (!GetTrieValue(h_past_clients, userid, h_client_trie))
        {
            h_client_trie = CreateTrie();
        }
        h_client_cvars[client] = h_client_trie;
    }

    if (!GetTrieValue(h_client_trie, cvar_name, client_prev_value))
    {
        b_new_client = true;
        if (!SetTrieValue(h_client_trie, cvar_name, cvar_int))
        {
            LogError("Unable to insert value into client trie for cvar %s", cvar_name);
        }
    }

    if (cvar_int > cvar_upper_bound)
    {
        //LogMessage("%s (%s) @ %s has %s OUTSIDE BOUNDS. REPORTING", client_name, client_auth, client_ip, cvar_name);
        b_report = true;
        b_cvar_high = true;
    }
    else if (cvar_int < cvar_lower_bound)
    {
        b_report = true;
    }

    if (b_report)
    {
        //LogMessage("new client: %b prev value: %d current value: %d compare: %b", b_new_client, client_prev_value, cvar_int, cvar_int != client_prev_value);
        if ((cvar_int != client_prev_value) || (b_new_client))
        {
            LogMessage("Client is new and must be reported, or has changed the CVar value for %s from %d to %d", cvar_name, client_prev_value, cvar_int);
            Format(client_report, sizeof(client_report), "CVAR_REPORT!%s!%s!%s!%s!%s", client_name, client_auth, client_ip, cvar_name, cvar_value);
            sendSocketData(client_report);

            SetTrieValue(h_client_trie, cvar_name, cvar_int); //update the trie with the new value

            b_player_warned[client] = false;
        }
        //CVAR_REPORT!NAME!ID!IP!CVAR!VALUE
        if (!b_player_warned[client])
        {
            CPrintToChatAll("{red}WARNING: {green}%s{default} (%s) is using an illegal CVar value for \"{olive}%s{default}\" (%s). This incident has been reported", client_name, client_auth, cvar_name, cvar_value);
            PrintToChat(client, "WARNING: You are using an illegal CVar value for \"%s\" (%s). You will be banned if you do not change it within two minutes. This incident has been reported", cvar_name, cvar_value);

            b_player_warned[client] = true;
        }
        else if ((b_cvar_high) && (b_player_warned[client]))
        {
            //player has been warned, and the CVar is ABOVE the limit. KICK CLIENT
            //KickClient(client, "Invalid CVar value for \"%s\"", cvar_name);
            decl String:kick_ban_msg[64];

            Format(kick_ban_msg, sizeof(kick_ban_msg), "Invalid CVar \"%s\" (%s)", cvar_name, cvar_value);
            BanClient(client, 60, BANFLAG_AUTO|BANFLAG_AUTHID, kick_ban_msg);

            CPrintToChatAll("{green}%s{default} has been banned for not changing invalid CVar \"{olive}%s{default}\" after being warned", client_name, cvar_name);

            Format(client_report, sizeof(client_report), "CVAR_REPORT-BAN!%s!%s!%s!%s!%s", client_name, client_auth, client_ip, cvar_name, cvar_value);
            sendSocketData(client_report);
        }
    }
}

public Action:gogoGadgetDetective(client, args)
{
    if (client == 0)
    {
        checkCVars();
    }
}

public onSocketConnected(Handle:socket, any:arg)
{
    decl String:msg[256];

    ResetPack(arg); //arg is a datapack containing the message to send, need to get back to the starting position
    ReadPackString(arg, msg, sizeof(msg)); //msg now contains what we want to send

    SocketSend(socket, msg);
}

public onSocketReceive(Handle:socket, String:rcvd[], const dataSize, any:arg)
{
    LogMessage("Received message %s", rcvd);
}

public onSocketDisconnect(Handle:socket, any:arg)
{
    CloseHandle(socket);
}

public onSocketSendQueueEmpty(Handle:socket, any:arg) 
{
    SocketDisconnect(socket);
    CloseHandle(socket);
}

public onSocketError(Handle:socket, const errorType, const errorNum, any:arg)
{
    LogError("SOCKET ERROR %d (errno %d)", errorType, errorNum);
    CloseHandle(socket);
}

public sendSocketData(String:msg[])
{
    new Handle:socket = SocketCreate(SOCKET_UDP, onSocketError);

    SocketSetSendqueueEmptyCallback(socket, onSocketSendQueueEmpty);

    decl String:botIP[32];
    new botPort;

    GetConVarString(ipgn_botip, botIP, sizeof(botIP));
    botPort = GetConVarInt(ipgn_botport);

    new Handle:socket_pack = CreateDataPack();
    WritePackString(socket_pack, msg);

    SocketSetArg(socket, socket_pack);

    SocketConnect(socket, onSocketConnected, onSocketReceive, onSocketDisconnect, botIP, botPort);
}

checkCVars()
{
    new Handle:h_cvar_array;
    decl String:cvar_name[64];


    for (new i = 1; i <= MaxClients; i++)
    {
        if (IsClientConnected(i) && !IsFakeClient(i))
        {
            if (h_client_cvars[i] == INVALID_HANDLE)
            {
                decl String:userid[8];
                IntToString(GetClientUserId(i), userid, sizeof(userid));

                if (!GetTrieValue(h_past_clients, userid, h_client_cvars[i]))
                {
                    h_client_cvars[i] = CreateTrie();
                }
            }

            new i_cvars = GetArraySize(h_cvars);

            for (new j = 0; j < i_cvars; j++)
            {
                //check if the client has been kicked mid-way
                //if (!IsClientConnected(i))
                //    break;

                h_cvar_array = GetArrayCell(h_cvars, j);

                GetArrayString(h_cvar_array, CVAR_ARRAY_NAME, cvar_name, sizeof(cvar_name));
                QueryClientConVar(i, cvar_name, clientCVarCallback);
            }
            
        }
    }  
}


addCVar(const String:cvar_name[], Float:cvar_minvalue, Float:cvar_maxvalue)
{
    LogMessage("Adding CVar %s to checking array", cvar_name);

    new Handle:h_cvar_array = CreateArray(64);
    PushArrayString(h_cvar_array, cvar_name);
    PushArrayCell(h_cvar_array, cvar_minvalue);
    PushArrayCell(h_cvar_array, cvar_maxvalue);

    new array_index = PushArrayCell(h_cvars, h_cvar_array);

    SetTrieValue(h_cvar_index, cvar_name, array_index);

    //LogMessage("cvar array added at index %d to global cvar array", array_index);
}