"""Unit tests for the agent loop and model wrapper (no real model needed)."""

import json

import pytest

import agent
import utils
from agent import Agent
from tools import TOOL_FUNCTIONS, TOOL_REGISTRY


class FakeModel:
    """Scriptable stand-in for a llama-cpp-python Llama instance."""

    def __init__(self, *responses):
        self.responses = list(responses)
        self.requests = []

    def create_chat_completion(self, messages, **kwargs):
        self.requests.append({"messages": list(messages), "kwargs": kwargs})
        if not self.responses:
            raise AssertionError("FakeModel ran out of scripted responses")
        return {"choices": [{"message": {"content": self.responses.pop(0)}}]}


# -- prompt & registry --------------------------------------------------------


def test_registry_and_functions_in_sync():
    assert set(TOOL_FUNCTIONS) == {tool["name"] for tool in TOOL_REGISTRY}


def test_format_tool_schemas_lists_tools():
    text = agent.format_tool_schemas(TOOL_REGISTRY)
    for name in ("list_files", "launch_app", "edit_config", "browse_page"):
        assert name in text


def test_system_prompt_includes_tools():
    a = Agent(model=FakeModel('{"answer": "hi"}'))
    assert "list_files" in a.system_prompt
    assert "terminate_process" in a.system_prompt


# -- basic conversation ---------------------------------------------------------


def test_direct_answer():
    a = Agent(model=FakeModel('{"answer": "Hello!"}'))
    result = a.chat("hi")
    assert result["answer"] == "Hello!"
    assert result["tool_calls"] == []


def test_garbage_output_becomes_answer():
    a = Agent(model=FakeModel("Sorry, I can't do that right now."))
    result = a.chat("help")
    assert result["answer"] == "Sorry, I can't do that right now."
    assert result["tool_calls"] == []


def test_answer_surrounded_by_prose():
    a = Agent(model=FakeModel('Here you go: {"answer": "Done"} hope that helps!'))
    result = a.chat("do it")
    assert result["answer"] == "Done"


# -- tool calling ---------------------------------------------------------------


def test_single_tool_call_then_answer(tmp_path):
    config = {"safety": {"allowed_dirs": [str(tmp_path)]}}
    a = Agent(
        model=FakeModel(
            json.dumps({"tool": "list_files", "arguments": {"path": str(tmp_path)}}),
            json.dumps({"answer": "The directory is empty."}),
        ),
        config=config,
    )
    result = a.chat("what is in tmp?")
    assert result["answer"] == "The directory is empty."
    assert [call["tool"] for call in result["tool_calls"]] == ["list_files"]
    # The tool result was fed back to the model for the second generation.
    tool_message = a.model.requests[-1]["messages"][-1]["content"]
    assert '"count": 0' in tool_message


def test_multiple_tools_at_once(tmp_path):
    config = {"safety": {"allowed_dirs": [str(tmp_path)]}}
    calls = {
        "tools": [
            {"tool": "list_files", "arguments": {"path": str(tmp_path)}},
            {"tool": "find_files", "arguments": {"root": str(tmp_path), "name": "x"}},
        ]
    }
    a = Agent(model=FakeModel(json.dumps(calls), json.dumps({"answer": "done"})), config=config)
    result = a.chat("go")
    assert len(result["tool_calls"]) == 2
    assert result["answer"] == "done"


def test_string_arguments_are_parsed(tmp_path):
    """Regression test: small models often emit arguments as a JSON string."""
    config = {"safety": {"allowed_dirs": [str(tmp_path)]}}
    a = Agent(
        model=FakeModel(
            json.dumps({"tool": "list_files", "arguments": json.dumps({"path": str(tmp_path)})}),
            json.dumps({"answer": "done"}),
        ),
        config=config,
    )
    result = a.chat("list")
    # The tool actually executed (its result was fed back) — no TypeError.
    tool_message = a.model.requests[-1]["messages"][-1]["content"]
    assert '"count": 0' in tool_message
    assert "Invalid arguments" not in tool_message
    assert result["answer"] == "done"


def test_unparseable_string_arguments_fall_back_to_empty(tmp_path):
    config = {"safety": {"allowed_dirs": [str(tmp_path)]}}
    a = Agent(
        model=FakeModel(
            json.dumps({"tool": "list_files", "arguments": "not json at all"}),
            json.dumps({"answer": "done"}),
        ),
        config=config,
    )
    a.chat("list")
    tool_message = a.model.requests[-1]["messages"][-1]["content"]
    # The call executed with default arguments instead of raising a TypeError.
    assert '"tool": "list_files"' in tool_message
    assert "Invalid arguments" not in tool_message


def test_tool_results_message_instructs_model():
    a = Agent(
        model=FakeModel(
            json.dumps({"tool": "list_files", "arguments": {"path": "."}}),
            json.dumps({"answer": "done"}),
        )
    )
    a.chat("list")
    tool_message = a.model.requests[-1]["messages"][-1]["content"]
    assert "ONLY the information in these results" in tool_message


def test_unknown_tool_is_reported():
    a = Agent(
        model=FakeModel(
            json.dumps({"tool": "do_magic", "arguments": {}}),
            json.dumps({"answer": "I could not do it."}),
        )
    )
    result = a.chat("do magic")
    tool_message = a.model.requests[-1]["messages"][-1]["content"]
    assert "Unknown tool" in tool_message
    assert result["answer"] == "I could not do it."


def test_invalid_arguments_reported():
    a = Agent(
        model=FakeModel(
            json.dumps({"tool": "terminate_process", "arguments": {"pid": "not-a-number"}}),
            json.dumps({"answer": "Something went wrong."}),
        )
    )
    result = a.chat("kill it", assume_yes=True)
    tool_message = a.model.requests[-1]["messages"][-1]["content"]
    assert "terminate_process" in tool_message
    assert result["answer"] == "Something went wrong."


# -- safety & confirmation --------------------------------------------------------


def test_dangerous_tool_rejected_when_not_interactive():
    a = Agent(
        model=FakeModel(
            json.dumps({"tool": "close_window", "arguments": {"ref": "x"}}),
            json.dumps({"answer": "The user declined."}),
        )
    )
    result = a.chat("close x", interactive=False)
    tool_message = a.model.requests[-1]["messages"][-1]["content"]
    assert "Rejected by user" in tool_message
    assert result["answer"] == "The user declined."


def test_dangerous_tool_allowed_with_assume_yes():
    a = Agent(
        model=FakeModel(
            json.dumps({"tool": "terminate_process", "arguments": {"pid": 999999}}),
            json.dumps({"answer": "ok"}),
        )
    )
    a.chat("kill it", interactive=False, assume_yes=True)
    tool_message = a.model.requests[-1]["messages"][-1]["content"]
    assert "Rejected" not in tool_message


def test_custom_confirm_callback_overrides_prompt():
    approvals = []

    def confirm(name, arguments):
        approvals.append((name, arguments))
        return False

    a = Agent(
        model=FakeModel(
            json.dumps({"tool": "close_window", "arguments": {"ref": "x"}}),
            json.dumps({"answer": "ok"}),
        ),
        confirm=confirm,
    )
    a.chat("close x")
    assert approvals == [("close_window", {"ref": "x"})]
    tool_message = a.model.requests[-1]["messages"][-1]["content"]
    assert "Rejected by user" in tool_message


# -- loop control -------------------------------------------------------------------


def test_iteration_limit_stops_loop():
    call = json.dumps({"tool": "list_files", "arguments": {"path": "."}})
    a = Agent(model=FakeModel(*[call] * 3), config={"agent": {"max_tool_iterations": 3}})
    result = a.chat("go")
    assert result["iterations"] == 3
    assert "could not finish" in result["answer"].lower()


def test_history_is_trimmed():
    a = Agent(model=FakeModel(*['{"answer": "hi"}'] * 10), config={"agent": {"max_history_messages": 4}})
    for i in range(10):
        a.chat(f"msg {i}")
    for request in a.model.requests:
        # system + at most 4 history messages + the assistant reply
        assert len(request["messages"]) <= 6


def test_reset_clears_history():
    a = Agent(model=FakeModel('{"answer": "one"}', '{"answer": "two"}'))
    a.chat("first")
    a.reset()
    a.chat("second")
    second_request = a.model.requests[-1]["messages"]
    assert all(message.get("content") != "first" for message in second_request)


# -- model loading ---------------------------------------------------------------------


def test_missing_model_file_raises(tmp_path):
    with pytest.raises(utils.AidoError, match="Model file not found"):
        Agent(model_path=str(tmp_path / "nope.gguf"))


def test_close_calls_model_close():
    class ClosableModel(FakeModel):
        def __init__(self):
            super().__init__('{"answer": "hi"}')
            self.closed = False

        def close(self):
            self.closed = True

    model = ClosableModel()
    a = Agent(model=model)
    a.close()
    assert model.closed
