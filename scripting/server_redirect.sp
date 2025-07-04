#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <socket>

#define PLUGIN_VERSION "1.0.4 / Fix for FOOLISH"
#define PLUGIN_DESCRIPTION "Provides live server info with join option"
#define MAX_SERVERS 10
#define REFRESH_TIME 60.0
#define SERVER_TIMEOUT 10.0
#define MAX_STR_LEN 160
#define MAX_INFO_LEN 200

#define A2S_INFO "\xFF\xFF\xFF\xFF\x54Source Engine Query"
#define A2S_SIZE 25

int
	g_iServerCount,
	g_iAdvertCount,
	g_iAdvertInterval = 1,
	g_iServerPort[MAX_SERVERS],
    g_iServerPlayerCount[MAX_SERVERS],
    g_iServerMaxPlayerCount[MAX_SERVERS];
char
	g_sServerName[MAX_SERVERS][MAX_STR_LEN],
	g_sServerAddress[MAX_SERVERS][MAX_STR_LEN],
	g_sServerInfo[MAX_SERVERS][MAX_INFO_LEN],
	g_sAddress[MAXPLAYERS+1][MAX_STR_LEN],
	g_sServer[MAXPLAYERS+1][MAX_INFO_LEN];
bool
	g_bSocketError[MAX_SERVERS],
	g_bConnectedFromFavorites[MAXPLAYERS+1],
	g_bLateLoad,
	g_bCoolDown;
Handle
	g_hSocket[MAX_SERVERS];
ConVar
	g_cvarHopTrigger,
	g_cvarServerFormat,
	g_cvarBroadcastHops,
	g_cvarAdvert,
	g_cvarAdvert_Interval,
    g_cvarEnableReroute;

public Plugin myinfo = {
	name = "Server Hop(Server Redirect)",
	author = "[GRAVE] rig0r, JoinedSenses / FOOLISH",
	description = PLUGIN_DESCRIPTION,
	version = PLUGIN_VERSION,
	url = "https://github.com/JoinedSenses/TF2-ServerHop"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
	if (GetEngineVersion() == Engine_CSGO) {
		strcopy(error, err_max, "ServerHop is incompatible with this game");
		return APLRes_SilentFailure;		
	}

	g_bLateLoad = late;
	return APLRes_Success;
}

public void OnPluginStart() {
	LoadTranslations("serverhop.phrases");

	CreateConVar("sm_serverhop_version", PLUGIN_VERSION, PLUGIN_DESCRIPTION, FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD).SetString(PLUGIN_VERSION);
  // convar setup
	g_cvarHopTrigger = CreateConVar(
		"sm_hop_trigger",
		"!servers",
		"What players have to type in chat to activate the plugin (besides !hop)"
	);
	g_cvarServerFormat = CreateConVar(
		"sm_hop_serverformat",
		"%name - %map (%numplayers/%maxplayers)",
		"Defines how the server info should be presented"
	);
	g_cvarBroadcastHops = CreateConVar(
		"sm_hop_broadcasthops",
		"1",
		"Set to 1 if you want a broadcast message when a player hops to another server"
	);
	g_cvarAdvert = CreateConVar(
		"sm_hop_advertise",
		"1",
		"Set to 1 to enable server advertisements"
	);
	g_cvarAdvert_Interval = CreateConVar(
		"sm_hop_advertisement_interval",
		"1",
		"Advertisement interval: advertise a server every x minute(s)"
	);
    g_cvarEnableReroute = CreateConVar(
        "sm_hop_reroute_enable",
        "0",
        "Set to 1 when main server is not full, you cat reoute to another server for main server."
    );

	AutoExecConfig(true, "plugin.serverhop");

	Handle timer = CreateTimer(REFRESH_TIME, RefreshServerInfo, _, TIMER_REPEAT);

	RegConsoleCmd("say", Command_Say);
	RegConsoleCmd("say_team", Command_Say);
	RegConsoleCmd("sm_hop", Command_Hop, "Hop servers.");
	RegConsoleCmd("sm_servers", Command_Servers, "Hop servers.");

	char path[MAX_STR_LEN];

	BuildPath(Path_SM, path, sizeof(path), "configs/serverhop.cfg");
	KeyValues kv = new KeyValues("Servers");

	if (!kv.ImportFromFile(path)) {
		LogToGame("Error loading server list");
		SetFailState("Unable to import server list from file.");
	}

	int i;
	kv.Rewind();
	if (!kv.GotoFirstSubKey()) {
		SetFailState("Unable to find first server in file.");	
	}
	
	do {
		kv.GetSectionName(g_sServerName[i], MAX_STR_LEN);
		kv.GetString("address", g_sServerAddress[i], MAX_STR_LEN);
		g_iServerPort[i] = kv.GetNum("port", 27015);
	} while (++i < MAX_SERVERS && kv.GotoNextKey());

	if (i == MAX_SERVERS && kv.GotoNextKey()) {
		LogError("You have exceeded the cap for max servers of %i. To add more, edit the value of MAX_SERVERS and recompile.", MAX_SERVERS);
	}

	delete kv;
	
	g_iServerCount = i;

	TriggerTimer(timer);
	
	if (g_bLateLoad) {
		char clientConnectMethod[64];
		for (int client = 1; client <= MaxClients; client++) {
			if (IsClientInGame(client) && !IsFakeClient(client)) {
				GetClientInfo(client, "cl_connectmethod", clientConnectMethod, sizeof(clientConnectMethod));

				if (!StrEqual(clientConnectMethod, "serverbrowser_internet")) {
					g_bConnectedFromFavorites[client] = true;
				}
			}
		}
	}
}

public Action Command_Hop(int client, int args) {
	ServerMenu(client);
	return Plugin_Handled;
}

public Action Command_Servers(int client, int args) {
	ServerMenu(client);
	return Plugin_Handled;
}

public Action Command_Say(int client, int args) {
	char text[MAX_STR_LEN];
	int startidx = 0;

	if (!GetCmdArgString(text, sizeof(text))) {
		return Plugin_Continue;
	}

	int last = strlen(text) - 1;
	if (text[last] == '\"') {
		text[last] = '\0';
		startidx = 1;
	}

	char trigger[MAX_STR_LEN];
	g_cvarHopTrigger.GetString(trigger, sizeof(trigger));

	if (strcmp(text[startidx], trigger, false) == 0 || strcmp(text[startidx], "!hop", false) == 0) {
		ServerMenu(client);
	}

	return Plugin_Continue;
}


public void OnClientPutInServer(int client) {
	char clientConnectMethod[64];
	GetClientInfo(client, "cl_connectmethod", clientConnectMethod, sizeof(clientConnectMethod));
	if (!StrEqual(clientConnectMethod, "serverbrowser_internet")) {
		g_bConnectedFromFavorites[client] = true;
	}

    if(!g_cvarEnableReroute.BoolValue) return;

    if(!CheckTime()) return;

    if(IsFakeClient(client)) return;

    CreateTimer(0.1, AdminCheckKick, EntIndexToEntRef(client), TIMER_FLAG_NO_MAPCHANGE);
}

public void OnClientDisconnect(int client) {
	g_bConnectedFromFavorites[client] = false;
}

public Action ServerMenu(int client) {
	char serverNumStr[MAX_STR_LEN];
	char menuTitle[MAX_STR_LEN];

	Menu menu = new Menu(Menu_Handler, MENU_ACTIONS_DEFAULT);
	Format(menuTitle, sizeof(menuTitle), "%T", "SelectServer", client);
	menu.SetTitle(menuTitle);

	for (int i = 0; i < g_iServerCount; i++) {
		if (strlen(g_sServerInfo[i]) > 0) {
			IntToString(i, serverNumStr, sizeof(serverNumStr));
			menu.AddItem(serverNumStr, g_sServerInfo[i]);
		}
	}
	menu.Display(client, 20);

	return Plugin_Handled;
}

public int Menu_Handler(Menu menu, MenuAction action, int param1, int param2) {
	if (action == MenuAction_Select) {
		char infobuf[MAX_STR_LEN];

		menu.GetItem(param2, infobuf, sizeof(infobuf));
		int serverNum = StringToInt(infobuf);
		char menuTitle[MAX_STR_LEN];
		Format(menuTitle, sizeof(menuTitle), "%T", "AboutToJoinServer", param1);
		Format(g_sAddress[param1], MAX_STR_LEN, "%s:%i", g_sServerAddress[serverNum], g_iServerPort[serverNum]);
		g_sServer[param1] = g_sServerInfo[serverNum];

		if (!g_bConnectedFromFavorites[param1]) {
			PrintToChat(param1, "\x01[\x03ServerHop\x01] Due to Valve game change, clients must connect via favorites to be redirected by server.");
			PrintToChat(param1, "\x01[\x03ServerHop\x01] %s:\x03 %s", g_sServer[param1], g_sAddress[param1]);
			return 0;
		}

		Panel panel = new Panel();
		panel.SetTitle(menuTitle);
		panel.DrawText(g_sServerInfo[serverNum]);
		panel.DrawText("Is this correct?");
		panel.CurrentKey = 3;
		panel.DrawItem("Accept");
		panel.DrawItem("Decline");
		panel.Send(param1, MenuConfirmHandler, 15);

		delete panel;
	}
	else if (action == MenuAction_End) {
		delete menu;
	}

	return 0;
}

public int MenuConfirmHandler(Menu menu, MenuAction action, int param1, int param2) {
	if (param2 == 3) {
		ClientCommand(param1, "redirect %s", g_sAddress[param1]);
		// broadcast to all
		if (g_cvarBroadcastHops.BoolValue) {
			char clientName[MAX_NAME_LENGTH];
			GetClientName(param1, clientName, sizeof(clientName));
			PrintToChatAll("\x01[\x03hop\x01] %t", "HopNotification", clientName, g_sServer[param1]);
		}
	}
	g_sAddress[param1][0] = '\0';
	g_sServer[param1][0] = '\0';

	return 0;
}

public Action RefreshServerInfo(Handle timer) {
	for (int i = 0; i < g_iServerCount; i++) {
		g_sServerInfo[i][0] = '\0';
		g_bSocketError[i] = false;
		delete g_hSocket[i];
		g_hSocket[i] = SocketCreate(SOCKET_UDP, OnSocketError);
		SocketSetArg(g_hSocket[i], i);
		SocketConnect(g_hSocket[i], OnSocketConnected, OnSocketReceive, OnSocketDisconnected, g_sServerAddress[i], g_iServerPort[i]);
	}

	CreateTimer(SERVER_TIMEOUT, CleanUp);

	return Plugin_Continue;
}

public Action CleanUp(Handle timer) {
	for (int i = 0; i < g_iServerCount; i++) {
		if (strlen(g_sServerInfo[i]) == 0 && !g_bSocketError[i]) {
			LogError("Server %s:%i is down, no reply received within %0.0f seconds.", g_sServerAddress[i], g_iServerPort[i], SERVER_TIMEOUT);
			delete g_hSocket[i];
		}
	}

	// all server info is up to date: advertise
	if (g_cvarAdvert.BoolValue) {
		if (g_iAdvertInterval == g_cvarAdvert_Interval.FloatValue) {
			Advertise();
		}
		if (++g_iAdvertInterval > g_cvarAdvert_Interval.FloatValue) {
			g_iAdvertInterval = 1;
		}
	}

	return Plugin_Handled;
}

public void Advertise() {
	char trigger[MAX_STR_LEN];
	g_cvarHopTrigger.GetString(trigger, sizeof(trigger));

	// skip servers being marked as down
	while (strlen(g_sServerInfo[g_iAdvertCount]) == 0) {
		if (++g_iAdvertCount >= g_iServerCount) {
			g_iAdvertCount = 0;
			break;
		}
	}

	if (strlen(g_sServerInfo[g_iAdvertCount]) > 0) {
		PrintToChatAll("\x01[\x03hop\x01] %t", "Advert", g_sServerInfo[g_iAdvertCount], trigger);

		if (++g_iAdvertCount >= g_iServerCount) {
			g_iAdvertCount = 0;
		}
	}
}

public void OnSocketConnected(Handle sock, any i) {
	SocketSend(sock, A2S_INFO, A2S_SIZE);
}

enum struct ByteReader {
	int data[1024];
	int size;
	int offset;

	void SetData(const char[] data, int dataSize, int offset) {
		for (int i = 0; i < dataSize; ++i) {
			this.data[i] = data[i];
		}
		this.data[dataSize] = 0;
		this.size = dataSize;
		this.offset = offset;
	}

	int GetByte() {
		return this.data[this.offset++];
	}

	void GetString(char[] str = "", int size = 0) {
		int j = 0;
		for (int i = this.offset; i < this.size; ++i, ++j) {
			if (j < size) {
				str[j] = this.data[i];
			}

			if (this.data[i] == '\x0') {
				break;
			}
		}

		this.offset += j + 1;
	}
}

public void OnSocketReceive(Handle sock, char[] data, const int dataSize, any arg) {
	/** ==== Request Format
	 * \xFF\xFF\xFF\xFF --------------- | Long
	 * Header: 'T' -------------------- | Byte
	 * Payload: "Source Engine Query\0" | String
	 * Challenge if response header 'A' | Long
	 */

	/** ==== Challenge Response
	 * \xFF\xFF\xFF\xFF --------------- | Long
	 * Header: 'A' -------------------- | Byte
	 * Challenge ---------------------- | Long
	 */

	/** ==== Normal Response
	 * \xFF\xFF\xFF\xFF --------------- | Long
	 * Header: 'I' -------------------- | Byte
	 * Protocol ----------------------- | Byte
	 * Name --------------------------- | String
	 * Map ---------------------------- | String
	 * Folder ------------------------- | String
	 * Game --------------------------- | String
	 * ID ----------------------------- | Short
	 * Players ------------------------ | Byte
	 * Max Players -------------------- | Byte
	 * Bots --------------------------- | Byte
	 * Server type -------------------- | Byte
	 * Environment -------------------- | Byte
	 * Visibility --------------------- | Byte
	 * VAC ---------------------------- | Byte
	 * if The Ship: Mode -------------- | Byte
	 * if The Ship: Witnesses --------- | Byte
	 * if The Ship: Duration ---------- | Byte
	 * Version ------------------------ | String
	 * Extra Data Flag ---------------- | Byte
	 * if EDF & 0x80: Port ------------ | Short
	 * if EDF & 0x10: SteamID --------- | Long Long
	 * if EDF & 0x40: STV Port -------- | Short
	 * if EDF & 0x40: STV Name -------- | String
	 * if EDF & 0x20: Tags ------------ | String
	 * if EDF & 0x01: GameID ---------- | Long Long
	 */

	ByteReader byteReader;
	byteReader.SetData(data, dataSize, 4); // begin at 5th byte, index 4

	// header
	if (byteReader.GetByte() == 'A') { // challenge response received
		static char reply[A2S_SIZE + 4] = A2S_INFO;

		for (int i = A2S_SIZE, j = byteReader.offset; i < sizeof(reply); ++i, ++j) {
			reply[i] = data[j];
		}
		
		SocketSend(sock, reply, sizeof(reply));

		return;
	}

	// skip protocol
	byteReader.offset += 1;

	char hostName[64];
	byteReader.GetString(hostName, sizeof(hostName));

	char mapName[80];
	byteReader.GetString(mapName, sizeof(mapName));

	// skip game directory
	byteReader.GetString();

	// skip game description
	byteReader.GetString();

	// skip gameid
	byteReader.offset += 2;

	int players = byteReader.GetByte();
    g_iServerPlayerCount[arg] = players;

	int maxPlayers = byteReader.GetByte();
    g_iServerMaxPlayerCount[arg] = maxPlayers;

	int bots = byteReader.GetByte();

	char format[MAX_STR_LEN];
	g_cvarServerFormat.GetString(format, sizeof(format));
	ReplaceString(format, strlen(format), "%name", g_sServerName[arg], false);
	ReplaceString(format, strlen(format), "%hostname", hostName);
	ReplaceString(format, strlen(format), "%map", mapName, false);

	char playersStr[4];
	IntToString(players, playersStr, sizeof(playersStr));
	ReplaceString(format, strlen(format), "%numplayers", playersStr, false);

	char maxPlayersStr[4];
	IntToString(maxPlayers, maxPlayersStr, sizeof(maxPlayersStr));
	ReplaceString(format, strlen(format), "%maxplayers", maxPlayersStr, false);

	char humans[4];
	IntToString(players - bots, humans, sizeof(humans));
	ReplaceString(format, strlen(format), "%humans", humans, false);

	char botsStr[4];
	IntToString(bots, botsStr, sizeof(botsStr));
	ReplaceString(format, strlen(format), "%bots", botsStr, false);

	g_sServerInfo[arg] = format;

	delete g_hSocket[arg];
}

public void OnSocketDisconnected(Handle sock, any i) {
	delete g_hSocket[i];
}

public void OnSocketError(Handle sock, const int errorType, const int errorNum, any i) {
	if (!g_bCoolDown) {
		LogError("Server %s:%i is down: socket error %d (errno %d)", g_sServerAddress[i], g_iServerPort[i], errorType, errorNum);
		CreateTimer(600.0, timerErrorCooldown);
		g_bCoolDown = true;
	}
	
	g_bSocketError[i] = true;

	delete g_hSocket[i];
}

Action timerErrorCooldown(Handle timer) {
	g_bCoolDown = false;
	return Plugin_Handled;
}

Action AdminCheckKick(Handle timer, int ref) {
    int client = EntRefToEntIndex(ref);
	if(!IsValidClient(client)) return Plugin_Continue;

    if(CheckCommandAccess(client, "sm_map", ADMFLAG_CHANGEMAP)) return Plugin_Continue;

    if(g_iServerPlayerCount[0] >= g_iServerMaxPlayerCount[0]) return Plugin_Continue;

	int KickAt = RoundToCeil(g_iServerPlayerCount[0] / 2.0);
	int playersOnServer = CountPlayersOnServer();

	if(playersOnServer <= KickAt) return Plugin_Continue;

	if(g_bConnectedFromFavorites[client])
	{
		ClientCommand(client,"redirect %s:%i", g_sServerAddress[0], g_iServerPort[0]);
	}
	else
	{
		KickClient(client, "%t", "RerouteKick", KickAt, g_sServerAddress[0], g_iServerPort[0]);
	}

	return Plugin_Continue;
}

int CountPlayersOnServer()
{
	int amount;
	
    for(int client=1; client <= MaxClients; client++)
	{
		if(IsClientConnected(client) && !IsFakeClient(client))
		{
			amount++;
		}
	}

	return amount;
}

bool CheckTime()
{
	char buffer[10];
	FormatTime(buffer, sizeof(buffer), "%H");
	int hour = StringToInt(buffer);

    return (16 < hour && hour <= 22) ? true : false;
}

stock bool IsValidClient(int client, bool replaycheck = true)
{
	return (0 < client && client <= MaxClients && IsClientInGame(client) && !GetEntProp(client, Prop_Send, "m_bIsCoaching")
	&& !(replaycheck && (IsClientSourceTV(client) || IsClientReplay(client))));
}