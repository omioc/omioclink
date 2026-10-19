"""服务器元信息与健康检查。"""

from fastapi.testclient import TestClient


def test_health(client: TestClient) -> None:
    response = client.get("/api/v1/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok", "peers": 0, "rooms": 0}


def test_server_info_exposes_ice_and_no_relay(client: TestClient) -> None:
    body = client.get("/api/v1/server/info").json()
    assert body["protocolVersion"] == 1
    assert body["iceServers"] == ["stun:test.local:3478"]
    assert all(server.startswith("stun:") for server in body["iceServers"])
    assert body["mediaRelay"] is False
    assert body["websocketPath"] == "/ws"
    assert body["maxRoomCapacity"] >= body["roomCapacity"] >= 2


def test_unknown_route_returns_structured_error(client: TestClient) -> None:
    response = client.get("/api/v1/nope")
    assert response.status_code == 404
    assert response.json()["code"] == "http_404"
