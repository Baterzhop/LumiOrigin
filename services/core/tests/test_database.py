from lumi_core.storage.database import Database


def test_database_migrates_and_persists_messages(tmp_path):
    db = Database(tmp_path / "lumi.sqlite3")
    db.migrate()
    conversation_id = db.create_conversation("test")
    db.add_message(conversation_id, "user", "hello")
    db.add_message(conversation_id, "assistant", "world", provider="fake", model="test")

    reopened = Database(tmp_path / "lumi.sqlite3")
    reopened.migrate()
    messages = reopened.list_messages(conversation_id)

    assert [m["role"] for m in messages] == ["user", "assistant"]
    assert messages[-1]["provider"] == "fake"
