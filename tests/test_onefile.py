import json
import os
import subprocess
import sys
import tempfile
import unittest

SERVER = os.path.join(os.path.dirname(__file__), "..", "onefile_mcp.py")


class OneFileServer(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.target = os.path.join(self.dir, "Assigned.swift")
        self.other = os.path.join(self.dir, "Other.swift")
        with open(self.other, "w") as f:
            f.write("untouched\n")

    def rpc(self, *calls):
        msgs = [{"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
                {"jsonrpc": "2.0", "method": "notifications/initialized"}]
        msgs += [{"jsonrpc": "2.0", "id": i + 1, "method": "tools/call",
                  "params": {"name": n, "arguments": a}} for i, (n, a) in enumerate(calls)]
        out = subprocess.run([sys.executable, SERVER, "--file", self.target],
                             input="\n".join(json.dumps(m) for m in msgs) + "\n",
                             capture_output=True, text=True, check=True).stdout
        return [json.loads(l) for l in out.splitlines()][1:]  # drop initialize reply

    def test_write_read_edit(self):
        r = self.rpc(("write_file", {"content": "let a = 1\n"}),
                     ("edit_file", {"old_string": "1", "new_string": "2"}),
                     ("read_file", {}))
        self.assertFalse(any(x["result"]["isError"] for x in r))
        self.assertEqual(r[2]["result"]["content"][0]["text"], "let a = 2\n")

    def test_no_tool_accepts_a_path(self):
        out = subprocess.run([sys.executable, SERVER, "--file", self.target],
                             input=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}) + "\n",
                             capture_output=True, text=True, check=True).stdout
        for tool in json.loads(out)["result"]["tools"]:
            self.assertNotIn("path", tool["inputSchema"]["properties"])
            self.assertFalse(tool["inputSchema"]["additionalProperties"])

    def test_extra_path_argument_is_ignored(self):
        # Even if a model invents a path argument, only the assigned file changes.
        self.rpc(("write_file", {"content": "x\n", "path": self.other}))
        with open(self.other) as f:
            self.assertEqual(f.read(), "untouched\n")
        with open(self.target) as f:
            self.assertEqual(f.read(), "x\n")

    def test_append_builds_file_in_chunks(self):
        r = self.rpc(("append_file", {"content": "line 1\n"}), ("append_file", {"content": "line 2\n"}),
                     ("read_file", {}))
        self.assertEqual(r[2]["result"]["content"][0]["text"], "line 1\nline 2\n")

    def test_ambiguous_edit_rejected(self):
        r = self.rpc(("write_file", {"content": "a a\n"}), ("edit_file", {"old_string": "a", "new_string": "b"}))
        self.assertTrue(r[1]["result"]["isError"])

    def test_symlink_resolved_at_launch(self):
        link = os.path.join(self.dir, "link.swift")
        os.symlink(self.other, link)
        out = subprocess.run([sys.executable, SERVER, "--file", link],
                             input=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}) + "\n",
                             capture_output=True, text=True, check=True).stdout
        self.assertIn(os.path.realpath(self.other), out)  # the bot is told the real target


if __name__ == "__main__":
    unittest.main()
