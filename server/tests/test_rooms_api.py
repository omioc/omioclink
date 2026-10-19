"""房间 REST 接口测试。"""

from fastapi.testclient import TestClient

from tests.conftest import auth_headers, create_room, register_user


def test_create_room_generates_readable_code(client: TestClient) -> None:
    token, user_id = register_user(client, "alice")
    room = create_room(client, token, name="日常聊天", capacity=5)

    assert len(room["roomId"]) == 6
    assert set(room["roomId"]) <= set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    assert room["ownerId"] == user_id
    assert room["ownerName"] == "alice"
    assert room["memberCount"] == 0
    assert room["hasPassword"] is False
    assert room["online"] is False
    assert room["joined"] is False


def test_public_room_list_contains_new_room(client: TestClient) -> None:
    token, _ = register_user(client, "alice")
    room = create_room(client, token)

    listing = client.get("/api/v1/rooms").json()
    assert listing["total"] == 1
    assert listing["items"][0]["roomId"] == room["roomId"]


def test_private_room_not_listed_but_visible_in_mine(client: TestClient) -> None:
    token, _ = register_user(client, "alice")
    room = create_room(client, token, name="测试房间", is_public=False)

    assert client.get("/api/v1/rooms").json()["total"] == 0
    mine = client.get("/api/v1/rooms?scope=mine", headers=auth_headers(token)).json()
    assert mine["total"] == 1
    assert mine["items"][0]["roomId"] == room["roomId"]


def test_mine_lists_created_rooms_of_both_visibilities(client: TestClient) -> None:
    """「我的房间」= 我创建的房间：公开、私有都要在，没进过房（joined=false）也不能漏。"""
    token, _ = register_user(client, "alice")
    public_room = create_room(client, token, name="我的公开房", is_public=True)
    private_room = create_room(client, token, name="我的私有房", is_public=False)

    # 对照组：别人建的公开房不该混进「我的房间」
    other_token, _ = register_user(client, "bob")
    foreign_room = create_room(client, other_token, name="别人的公开房")

    mine = client.get("/api/v1/rooms?scope=mine", headers=auth_headers(token)).json()
    ids = {item["roomId"] for item in mine["items"]}
    assert ids == {public_room["roomId"], private_room["roomId"]}
    assert all(item["joined"] is False for item in mine["items"])

    public_ids = {item["roomId"] for item in client.get("/api/v1/rooms").json()["items"]}
    assert public_ids == {public_room["roomId"], foreign_room["roomId"]}


def test_mine_requires_auth(client: TestClient) -> None:
    assert client.get("/api/v1/rooms?scope=mine").status_code == 401


def test_room_detail_and_password_flag(client: TestClient) -> None:
    token, _ = register_user(client, "alice")
    room = create_room(client, token, password="room-password")

    detail = client.get(f"/api/v1/rooms/{room['roomId']}").json()
    assert detail["hasPassword"] is True

    missing = client.get("/api/v1/rooms/ZZZZZZ")
    assert missing.status_code == 404
    assert missing.json()["code"] == "room_not_found"


def test_only_owner_can_update_or_delete(client: TestClient) -> None:
    owner_token, _ = register_user(client, "alice")
    other_token, _ = register_user(client, "bob")
    room = create_room(client, owner_token, capacity=5)
    room_id = room["roomId"]

    forbidden = client.patch(
        f"/api/v1/rooms/{room_id}", json={"name": "改名"}, headers=auth_headers(other_token)
    )
    assert forbidden.status_code == 403

    updated = client.patch(
        f"/api/v1/rooms/{room_id}", json={"name": "改名", "capacity": 3},
        headers=auth_headers(owner_token),
    )
    assert updated.status_code == 200
    assert updated.json()["name"] == "改名"
    assert updated.json()["capacity"] == 3

    assert client.delete(f"/api/v1/rooms/{room_id}", headers=auth_headers(other_token)).status_code == 403
    assert client.delete(f"/api/v1/rooms/{room_id}", headers=auth_headers(owner_token)).status_code == 204
    assert client.get(f"/api/v1/rooms/{room_id}").status_code == 404


def test_capacity_is_clamped_to_server_ceiling(client: TestClient) -> None:
    token, _ = register_user(client, "alice")
    room = create_room(client, token, capacity=8)
    assert room["capacity"] == 8


def test_members_endpoint_empty_when_nobody_joined(client: TestClient) -> None:
    token, _ = register_user(client, "alice")
    room = create_room(client, token)
    body = client.get(f"/api/v1/rooms/{room['roomId']}/members").json()
    assert body == {"items": [], "total": 0}


def test_leave_room_is_idempotent_without_connection(client: TestClient) -> None:
    token, _ = register_user(client, "alice")
    room = create_room(client, token)
    response = client.post(
        f"/api/v1/rooms/{room['roomId']}/leave", headers=auth_headers(token)
    )
    assert response.status_code == 200
    assert response.json() == {"left": 0}
