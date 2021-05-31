-module(serv).
-export([start/1, fin/0, awaitConnections/1, messagesHandler/1, acceptedConnections/1, parka/1]).

-define(CANAL_GENERAL, "General").
-define(LARGO_ENUM, 4).
-define(LARGO_UNION, 1096). %%Incluye dos bytes de padding
-define(LARGO_PAQUETE, 1100).

-define(LARGO_MESSAGE, 1024).
-define(LARGO_USERNAME, 35).
-define(LARGO_CHANNEL, 35).

-define(SERVER_NAME, "Server").

-define(TIPO_UNSET, 0).
-define(TIPO_USERNAME_MESSAGE, 1).
-define(TIPO_NAMED_TEXT_MESSAGE, 3).
-define(TIPO_RESPONSE_USERNAME_MESSAGE, 4).
-define(TIPO_PRIVATE_MESSAGE, 5).
-define(TIPO_USER_EXITS_MESSAGE, 6).
-define(TIPO_SERVER_TERMINATION_MESSAGE, 7).
-define(TIPO_USER_JOINS_MESSAGE, 8).

-record(cliente, {canal = ?CANAL_GENERAL, username = []}).

awaitConnections(Socket) ->
  case gen_tcp:accept(Socket, 50) of
    {ok, CSocket}  ->
      spawn(?MODULE, messagesHandler, [CSocket]),
      lista ! {nuevaPersona, CSocket};
    {error, closed} -> exit(closed);
    {error, timeout} -> ok
  end,

  receive
    {finalizar} -> ok
  after 0 ->
    awaitConnections(Socket)
  end.


acceptedConnections(Mapa) ->
  Result =
    receive
      {nuevaPersona, CSocket} ->
        maps:put(CSocket, #cliente{}, Mapa);
      {cambiarUsername, CSocket, Username} ->
        NewMapa =
          try maps:update_with(CSocket, fun(C) -> C#cliente{username=Username} end, Mapa)
          catch {badkey, _} ->
            io:format("Usuario con socket ~p no existe~n",[CSocket]),
            Mapa
          end,
        NewMapa;
      {cambiarCanal, CSocket, Canal} ->
        NewMapa =
          try maps:update_with(CSocket, fun(C) -> C#cliente{canal=Canal} end, Mapa)
          catch {badkey, _} ->
            io:format("Usuario con socket ~p no existe~n",[CSocket]),
            Mapa
          end,
        NewMapa;
    % 0 si no es valido Socket sino
      {usernameValido, Username, PId} ->
        I = maps:iterator(maps:filter((fun(_,V) -> (V#cliente.username == Username) end), Mapa)),
        case maps:next(I) of
          none -> PId ! ok;
          _ -> PId ! used
        end,
        Mapa;
      {desconectar, CSocket} ->
        maps:remove(CSocket, Mapa);
    %%Ver caso error
      {dameSockets, PId} ->
        PId ! maps:keys(Mapa),
        Mapa;
      {usernameSocket, CSocket, PId} ->
        Retorno =
          case maps:get(CSocket, Mapa, none) of
            none -> none;
            Cliente -> Cliente#cliente.username
          end,
        PId ! Retorno,
        Mapa;
      {socketGivenUsername, Username, PId} ->
        I = maps:iterator(maps:filter((fun(_,V) -> (V#cliente.username == Username) end), Mapa)),
        case maps:next(I) of
          none -> PId ! none;
          {K, _, _} -> PId ! K
        end,
        Mapa;
      {canalSocket, CSocket, PId} ->
        {ok, Cliente} = maps:find(CSocket, Mapa),
        PId ! Cliente#cliente.canal,
        Mapa;
      {finalizar} -> finalizar
    end,

  case Result of
    finalizar -> ok;
    M -> acceptedConnections(M)
  end.

binToList(Binario, Inicio, Final) ->
  binary:bin_to_list(Binario, {Inicio, Final - Inicio}).

desencriptadorDeMensajesRolingas(Paquete) ->
  case binary:at(Paquete, 1096) of
    ?TIPO_UNSET -> ok;
    ?TIPO_USERNAME_MESSAGE -> {usernameMessage, binToList(Paquete, 0, ?LARGO_USERNAME-1)};
    ?TIPO_NAMED_TEXT_MESSAGE -> {textMessage, binToList(Paquete, ?LARGO_USERNAME + ?LARGO_CHANNEL, ?LARGO_MESSAGE-1)};
    ?TIPO_PRIVATE_MESSAGE ->
      Receiver = binToList(Paquete, ?LARGO_USERNAME, ?LARGO_USERNAME + ?LARGO_USERNAME -1),
      Mensaje = binToList(Paquete, ?LARGO_USERNAME + ?LARGO_USERNAME, ?LARGO_MESSAGE -1),
      {privateMessage, Receiver, Mensaje};
    ?TIPO_USER_EXITS_MESSAGE -> {exitMessage};
    ?TIPO_USER_JOINS_MESSAGE -> {joinMessage, binToList(Paquete, ?LARGO_USERNAME, ?LARGO_USERNAME + ?LARGO_CHANNEL -1)}
  end.

% Usado es el largo en bytes del objecto que se busca paddear
crearPadding(Usado, Largo) -> [0 || _ <- lists:seq(Usado+1, Largo)].

% Mete la union en un struct message
meterEnMensaje(Union, Tipo) ->
  binary:list_to_bin(
    Union ++ crearPadding(length(Union), ?LARGO_UNION) ++
    [Tipo] ++ crearPadding(1, ?LARGO_ENUM)
  ).

crearResponseUsernameMessage(IsFailure) ->
  Num = if IsFailure -> 1; true -> 0 end,
  meterEnMensaje([Num], ?TIPO_RESPONSE_USERNAME_MESSAGE).

crearNamedTextMessage(Username, Channel, Mensaje) ->
  Union =
    Username ++ crearPadding(length(Username), ?LARGO_USERNAME) ++
    Channel ++ crearPadding(length(Channel), ?LARGO_CHANNEL) ++
    Mensaje ++ crearPadding(length(Mensaje), ?LARGO_MESSAGE),

  meterEnMensaje(Union, ?TIPO_NAMED_TEXT_MESSAGE).

crearPrivateTextMessage(Sender, Reciever, Mensaje) ->
  Union =
    Sender ++ crearPadding(length(Sender), ?LARGO_USERNAME) ++
    Reciever ++ crearPadding(length(Reciever), ?LARGO_USERNAME) ++
    Mensaje ++ crearPadding(length(Mensaje), ?LARGO_MESSAGE),

  meterEnMensaje(Union, ?TIPO_PRIVATE_MESSAGE).

crearExitMessage(Username, Canal) ->
  Union =
    Username ++ crearPadding(length(Username), ?LARGO_USERNAME) ++
    Canal ++ crearPadding(length(Canal), ?LARGO_CHANNEL),

  meterEnMensaje(Union, ?TIPO_USER_EXITS_MESSAGE).

crearJoinMessage(Username, Canal) ->
  Union =
    Username ++ crearPadding(length(Username), ?LARGO_USERNAME) ++
    Canal ++ crearPadding(length(Canal), ?LARGO_CHANNEL),
  meterEnMensaje(Union, ?TIPO_USER_JOINS_MESSAGE).

crearServerTerminationMessage() ->
  Union = [],
  meterEnMensaje(Union, ?TIPO_SERVER_TERMINATION_MESSAGE).

crearMensajeDeServidor(Mensaje) ->
  crearNamedTextMessage(?SERVER_NAME, ?CANAL_GENERAL, Mensaje).

enviarATodos(Paquete) ->
  lista ! { dameSockets, self() },
  Sockets = receive S -> S end,
  lists:map(fun(Socket) -> gen_tcp:send(Socket, Paquete) end, Sockets),
  ok.

binAPrint(L) -> [Y || Y <- L, Y =/= 0].

lidiarConPaquete(CSocket, Paquete) ->
  case desencriptadorDeMensajesRolingas(Paquete) of
    {usernameMessage, Username} ->
      case lists:nth(1, Username) of
        0 -> gen_tcp:send(CSocket, crearResponseUsernameMessage(true));
        _ ->
          lista ! {usernameValido, Username, self()},
          receive
            used -> gen_tcp:send(CSocket, crearResponseUsernameMessage(true)); %crear funcion crearMesanjeTipo4
            ok ->
              lista ! {cambiarUsername, CSocket, Username},
              gen_tcp:send(CSocket, crearResponseUsernameMessage(false)),
              io:format("--- Ha aparecido: ~s ---~n", [binAPrint(Username)])
          end
      end;

    {textMessage, Mensaje} ->
      lista ! {usernameSocket, CSocket, self()},
      Username = receive U -> U end, %% enviar a todos que sea un agente
      lista ! {canalSocket, CSocket, self()},
      Channel = receive C -> C end, %% enviar a todos que sea un agente
      enviarATodos(crearNamedTextMessage(Username, Channel, Mensaje)),
      io:format("[~s|~s]> ~s~n", [binAPrint(Channel), binAPrint(Username), binAPrint(Mensaje)]);

    {privateMessage, Receiver, Mensaje} ->
      lista ! {socketGivenUsername, Receiver, self()},
      receive
        none -> gen_tcp:send(CSocket, crearMensajeDeServidor("Fallo al enviar el mensaje privado (usuario no encontrado)")); %Hacer el mensaje y enviar que no anduvo
        PSocket ->
          lista ! {usernameSocket, CSocket, self()},
          Username = receive U -> U end,
          gen_tcp:send(PSocket, crearPrivateTextMessage(Username, Receiver, Mensaje)),
          gen_tcp:send(CSocket, crearPrivateTextMessage(Receiver, Username, Mensaje)),
          io:format("Se envio un mensaje privado ツ~n", [])
      end;

    {exitMessage} ->
      lista ! {usernameSocket, CSocket, self()},
      receive
        Username ->
          lista ! {canalSocket, CSocket, self()},
          receive
            _ ->
              enviarATodos(crearExitMessage(Username, ?CANAL_GENERAL)),
              io:format("Usuario ~s se desconecto~n", [binAPrint(Username)]),
              lista ! {desconectar, CSocket}
          end
      end;

    {joinMessage, CanalNuevo} ->
      % BUscar canal viejo
      lista ! {canalSocket, CSocket, self()},
      receive
        CanalViejo ->
          lista ! {usernameSocket, CSocket, self()},
          receive
          % Mandar mensaje de exit a todos con canal = canal viejo
            Username ->
              enviarATodos(crearExitMessage(Username, CanalViejo)), % Usamos Paquete que es igual que Mensaje ya que no lo extrajimos
              % Actualizar el nuevo canal en Mapa
              lista ! {cambiarCanal, CSocket, CanalNuevo},
              % ENviar un mensaje a todos con el nuevo canal.
              enviarATodos(crearJoinMessage(Username, CanalNuevo)),
              io:format("--- ~s cambio de sala a ~s ---~n", [binAPrint(Username), binAPrint(CanalNuevo)])
          end
      end
    end,
  messagesHandler(CSocket),
  ok.

messagesHandler(CSocket) ->
  case gen_tcp:recv(CSocket, 0) of
    {ok, Paquete} -> lidiarConPaquete(CSocket, Paquete);
    {error, closed} ->
      case whereis(lista) of
        undefined -> ok;
        _ ->
          lista ! {usernameSocket, CSocket, self()},
          receive
            none -> ok;
            Username ->
              enviarATodos(crearExitMessage(Username, ?CANAL_GENERAL)),
              io:format("Usuario ~s se desconecto~n", [binAPrint(Username)]),
              lista ! {desconectar, CSocket}
          end
      end
  end.

parka(Socket) ->
  receive
    finalizar -> gen_tcp:close(Socket)
  end.

fin() ->
  enviarATodos(crearServerTerminationMessage()),
  lista ! {finalizar},
  unregister(lista),
  await ! {finalizar},
  unregister(await),
  servidor ! {finalizar},
  unregister(servidor),
  ok.

%% start: Crear un socket, y ponerse a escuchar.
start(Puerto) ->
  case gen_tcp:listen(Puerto, [ binary, {active, false}]) of
    {ok, Socket} ->
      register(await, spawn(?MODULE, awaitConnections, [Socket])),
      register(lista, spawn(?MODULE, acceptedConnections, [maps:new()])),
      register(servidor, spawn(?MODULE, parka, [Socket]));
    {error, Reason} -> io:format("Falló abrir puerto por ~p~n",[Reason])
  end.