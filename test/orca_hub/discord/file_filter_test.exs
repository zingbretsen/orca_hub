defmodule OrcaHub.Discord.FileFilterTest do
  use ExUnit.Case, async: true

  alias OrcaHub.Discord.FileFilter

  describe "check_inbound_metadata/1" do
    test "allows an ordinary small file" do
      assert FileFilter.check_inbound_metadata(%{size: 1024}) == :allow
    end

    test "allows when size is unknown — can't judge what we can't see" do
      assert FileFilter.check_inbound_metadata(%{size: nil}) == :allow
      assert FileFilter.check_inbound_metadata(%{}) == :allow
    end

    test "denies a file over the per-file cap, naming the size and the limit" do
      assert {:deny, reason} =
               FileFilter.check_inbound_metadata(%{size: FileFilter.max_file_bytes() + 1})

      assert reason =~ "per-file limit"
    end

    test "allows a file exactly at the cap" do
      assert FileFilter.check_inbound_metadata(%{size: FileFilter.max_file_bytes()}) == :allow
    end
  end

  describe "check_inbound_content/1" do
    test "allows an ordinary file with bytes in hand" do
      assert FileFilter.check_inbound_content(%{size: 10, bytes: "hi"}) == :allow
    end

    test "denies content over the per-file cap even when metadata couldn't judge it" do
      assert {:deny, reason} =
               FileFilter.check_inbound_content(%{
                 size: FileFilter.max_file_bytes() + 1,
                 bytes: <<0>>
               })

      assert reason =~ "per-file limit"
    end
  end

  describe "check_outbound/1" do
    test "allows an ordinary file" do
      assert FileFilter.check_outbound(%{size: 1024}) == :allow
    end

    test "denies a file over the per-file cap" do
      assert {:deny, reason} =
               FileFilter.check_outbound(%{size: FileFilter.max_file_bytes() + 1})

      assert reason =~ "per-file limit"
    end
  end

  describe "check_total/2" do
    test "allows a total within the cap" do
      assert FileFilter.check_total(100, 200) == :allow
    end

    test "allows a total exactly at the cap" do
      assert FileFilter.check_total(200, 200) == :allow
    end

    test "denies a total over the cap" do
      assert {:deny, reason} = FileFilter.check_total(201, 200)
      assert reason =~ "exceeding"
    end
  end

  describe "cap accessors" do
    test "max_file_bytes/0 and max_inbound_total_bytes/0 are tunable, sane, and distinct" do
      assert FileFilter.max_file_bytes() > 0
      assert FileFilter.max_inbound_total_bytes() > FileFilter.max_file_bytes()
    end
  end

  describe "format_bytes/1" do
    test "formats sub-megabyte sizes in KB" do
      assert FileFilter.format_bytes(1024) == "1.0KB"
    end

    test "formats megabyte-and-up sizes in MB" do
      assert FileFilter.format_bytes(1_048_576) == "1.0MB"
    end
  end
end
