defmodule OrcaHub.Discord.BridgeTest do
  use ExUnit.Case, async: true

  alias OrcaHub.Discord.Bridge

  describe "sanitize_filename/1" do
    test "keeps a plain safe filename intact" do
      assert Bridge.sanitize_filename("report.pdf") == "report.pdf"
      assert Bridge.sanitize_filename("my_file-2.tar.gz") == "my_file-2.tar.gz"
    end

    test "strips any directory component (no traversal)" do
      assert Bridge.sanitize_filename("../../etc/passwd") == "passwd"
      assert Bridge.sanitize_filename("/abs/path/x.txt") == "x.txt"
      assert Bridge.sanitize_filename("nested/dir/name.png") == "name.png"
    end

    test "collapses unsafe characters to a single dash" do
      assert Bridge.sanitize_filename("my file (1).PNG") == "my-file-1-.PNG"
      assert Bridge.sanitize_filename("a  b__c.txt") == "a-b__c.txt"
    end

    test "falls back to \"file\" when it sanitizes to empty" do
      assert Bridge.sanitize_filename("") == "file"
      assert Bridge.sanitize_filename("..") == "file"
      assert Bridge.sanitize_filename("...") == "file"
      assert Bridge.sanitize_filename("   ") == "file"
      assert Bridge.sanitize_filename("😀") == "file"
    end

    test "never returns an absolute path or a traversal token" do
      for name <- ["../../../root", "/etc/shadow", "..\\..\\win", "....//x"] do
        result = Bridge.sanitize_filename(name)
        refute String.starts_with?(result, "/")
        refute String.contains?(result, "/")
        refute result == ".."
      end
    end

    test "is defensive against non-binary input" do
      assert Bridge.sanitize_filename(nil) == "file"
      assert Bridge.sanitize_filename(123) == "file"
    end
  end
end
