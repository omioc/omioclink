"""好友接口测试。"""

from fastapi.testclient import TestClient

from tests.conftest import auth_headers, register_user


def _request(client: TestClient, token: str, username: str) -> dict:
    response = client.post(
        "/api/v1/friends/requests", json={"username": username}, headers=auth_headers(token)
    )
    assert response.status_code == 201, response.text
    return response.json()


def test_full_friend_flow(client: TestClient) -> None:
    alice, _ = register_user(client, "alice")
    bob, bob_id = register_user(client, "bob")

    created = _request(client, alice, "bob")
    assert created["direction"] == "outgoing"
    assert created["user"]["id"] == bob_id

    # 双方各自看到一条待处理申请
    outgoing = client.get("/api/v1/friends/requests", headers=auth_headers(alice)).json()
    assert [item["direction"] for item in outgoing["items"]] == ["outgoing"]
    incoming = client.get("/api/v1/friends/requests", headers=auth_headers(bob)).json()
    assert [item["direction"] for item in incoming["items"]] == ["incoming"]

    # 接受后互为好友
    accepted = client.post(
        f"/api/v1/friends/requests/{incoming['items'][0]['id']}",
        json={"accept": True},
        headers=auth_headers(bob),
    )
    assert accepted.status_code == 200
    assert client.get("/api/v1/friends", headers=auth_headers(alice)).json()["total"] == 1
    friends_of_bob = client.get("/api/v1/friends", headers=auth_headers(bob)).json()
    assert friends_of_bob["items"][0]["user"]["username"] == "alice"
    assert friends_of_bob["items"][0]["online"] is False

    # 删除好友后双向清空
    assert client.delete("/api/v1/friends/alice", headers=auth_headers(bob)).status_code == 204
    assert client.get("/api/v1/friends", headers=auth_headers(alice)).json()["total"] == 0


def test_reject_request_removes_it(client: TestClient) -> None:
    alice, _ = register_user(client, "alice")
    bob, _ = register_user(client, "bob")
    _request(client, alice, "bob")

    incoming = client.get("/api/v1/friends/requests", headers=auth_headers(bob)).json()
    rejected = client.post(
        f"/api/v1/friends/requests/{incoming['items'][0]['id']}",
        json={"accept": False},
        headers=auth_headers(bob),
    )
    assert rejected.status_code == 200
    assert rejected.json() is None
    assert client.get("/api/v1/friends", headers=auth_headers(alice)).json()["total"] == 0


def test_duplicate_and_self_and_unknown_requests(client: TestClient) -> None:
    alice, _ = register_user(client, "alice")
    register_user(client, "bob")

    _request(client, alice, "bob")
    duplicate = client.post(
        "/api/v1/friends/requests", json={"username": "bob"}, headers=auth_headers(alice)
    )
    assert duplicate.status_code == 409
    assert duplicate.json()["code"] == "duplicate_request"

    self_request = client.post(
        "/api/v1/friends/requests", json={"username": "alice"}, headers=auth_headers(alice)
    )
    assert self_request.status_code == 422

    unknown = client.post(
        "/api/v1/friends/requests", json={"username": "ghost"}, headers=auth_headers(alice)
    )
    assert unknown.status_code == 404
    assert unknown.json()["code"] == "user_not_found"


def test_mutual_requests_become_friends_immediately(client: TestClient) -> None:
    alice, _ = register_user(client, "alice")
    bob, _ = register_user(client, "bob")

    _request(client, alice, "bob")
    second = _request(client, bob, "alice")
    assert second["direction"] == "outgoing"

    assert client.get("/api/v1/friends", headers=auth_headers(alice)).json()["total"] == 1
    assert client.get("/api/v1/friends", headers=auth_headers(bob)).json()["total"] == 1
    assert client.get("/api/v1/friends/requests", headers=auth_headers(alice)).json()["total"] == 0


def test_cancel_outgoing_request(client: TestClient) -> None:
    alice, _ = register_user(client, "alice")
    register_user(client, "bob")
    created = _request(client, alice, "bob")

    response = client.delete(
        f"/api/v1/friends/requests/{created['id']}", headers=auth_headers(alice)
    )
    assert response.status_code == 204
    assert client.get("/api/v1/friends/requests", headers=auth_headers(alice)).json()["total"] == 0


def test_remove_non_friend_returns_404(client: TestClient) -> None:
    alice, _ = register_user(client, "alice")
    register_user(client, "bob")
    response = client.delete("/api/v1/friends/bob", headers=auth_headers(alice))
    assert response.status_code == 404
    assert response.json()["code"] == "not_friends"


def test_cannot_send_request_to_existing_friend(client: TestClient) -> None:
    alice, _ = register_user(client, "alice")
    bob, _ = register_user(client, "bob")
    _request(client, alice, "bob")
    incoming = client.get("/api/v1/friends/requests", headers=auth_headers(bob)).json()
    client.post(
        f"/api/v1/friends/requests/{incoming['items'][0]['id']}",
        json={"accept": True},
        headers=auth_headers(bob),
    )
    again = client.post(
        "/api/v1/friends/requests", json={"username": "bob"}, headers=auth_headers(alice)
    )
    assert again.status_code == 409
    assert again.json()["code"] == "already_friends"
