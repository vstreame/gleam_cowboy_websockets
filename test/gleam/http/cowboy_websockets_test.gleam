import gleam/uri.{Uri}
import gleam/http.{Header}
import gleam/result
import gleam/list
import gleam/http/request
import gleam/erlang/charlist.{Charlist}
import gleam/dynamic.{Dynamic}
import gleam/result
import gleam/otp/actor
import gleam/otp/process.{Pid}
import gleam/http/cowboy_websockets as ws

//====VENDOR: NERF=====
// All taken from https://github.com/lpil/nerf/tree/main/src/nerf
// TODO: Remove this when nerf http 3.0 APIs is published
external type StreamReference

external type ConnectionPid

fn open(host: String, port: Int) -> Result(ConnectionPid, Dynamic) {
  open_erl(charlist.from_string(host), port)
}

external fn open_erl(Charlist, Int) -> Result(ConnectionPid, Dynamic) =
  "gun" "open"

external fn await_up(ConnectionPid) -> Result(Dynamic, Dynamic) =
  "gun" "await_up"

external fn ws_upgrade(ConnectionPid, String, List(Header)) -> StreamReference =
  "gun" "ws_upgrade"

external type OkAtom

external fn ws_send_erl(ConnectionPid, StreamReference, Frame) -> OkAtom =
  "gun" "ws_send"

fn ws_send(pid: ConnectionPid, stream_ref: StreamReference, frame: Frame) -> Nil {
  ws_send_erl(pid, stream_ref, frame)
  Nil
}

type Connection {
  Connection(ref: StreamReference, pid: ConnectionPid)
}

type Frame {
  Close
  Text(String)
  Binary(BitString)
}

fn connect(
  hostname: String,
  path: String,
  on port: Int,
  with headers: List(Header),
) -> Result(Connection, ConnectError) {
  try pid =
    open(hostname, port)
    |> result.map_error(ConnectionFailed)
  try _ =
    await_up(pid)
    |> result.map_error(ConnectionFailed)

  // Upgrade to websockets
  let ref = ws_upgrade(pid, path, headers)
  let conn = Connection(pid: pid, ref: ref)
  try _ =
    await_upgrade(conn, 1000)
    |> result.map_error(ConnectionFailed)

  // TODO: handle upgrade failure
  // https://ninenines.eu/docs/en/gun/2.0/guide/websocket/
  // https://ninenines.eu/docs/en/gun/1.2/manual/gun_error/
  // https://ninenines.eu/docs/en/gun/1.2/manual/gun_response/
  Ok(conn)
}

fn send(to conn: Connection, this message: String) -> Nil {
  ws_send(conn.pid, conn.ref, Text(message))
}

external fn receive(from: Connection, within: Int) -> Result(Frame, Nil) =
  "nerf_ffi" "ws_receive"

external fn await_upgrade(from: Connection, within: Int) -> Result(Nil, Dynamic) =
  "nerf_ffi" "ws_await_upgrade"

// TODO: listen for close events
fn close(conn: Connection) -> Nil {
  ws_send(conn.pid, conn.ref, Close)
}

/// The URI of the websocket server to connect to
type ConnectError {
  ConnectionRefused(status: Int, headers: List(Header))
  ConnectionFailed(reason: Dynamic)
}

//====VENDOR: NERF=====
type WSState {
  WSState(username: String, connected: Bool)
}

type Message {
  Subscribe(Pid)
  Broadcast(String)
}

pub fn websocket_test() {
  let port = 3082

  assert Ok(sender) =
    actor.start(
      [],
      fn(msg, state) {
        case msg {
          Subscribe(pid) -> actor.Continue([pid, ..state])
          Broadcast(msg) -> {
            state
            |> list.each(fn(pid) { process.untyped_send(pid, msg) })
            actor.Continue(state)
          }
        }
      },
    )

  assert Ok(_) =
    ws.start(
      fn(req) {
        ws.Upgrade(WSState(
          username: req
          |> request.get_header("x-username")
          |> result.unwrap(""),
          connected: False,
        ))
      },
      on_ws_init: fn(state) {
        process.send(sender, Subscribe(process.self()))
        ws.Ignore(WSState(..state, connected: True))
      },
      on_ws_frame: fn(state, frame) {
        case frame, state.connected {
          ws.Text("whois"), True -> ws.Respond(ws.Text(state.username), state)
          ws.Text("whois"), False ->
            ws.Respond(ws.Text("[not connected]"), state)
          _, _ -> ws.Ignore(state)
        }
      },
      on_info: fn(state, message) {
        case dynamic.string(message) {
          Ok(message) -> ws.Respond(ws.Text(message), state)
          _ -> ws.Ignore(state)
        }
      },
      on_port: port,
    )

  assert Ok(conn) = connect("0.0.0.0", "/", port, [#("x-username", "E")])

  send(conn, "whois")
  assert Ok(Text("E")) = receive(conn, 500)

  process.send(sender, Broadcast("echo"))
  assert Ok(Text("echo")) = receive(conn, 500)

  close(conn)
}
