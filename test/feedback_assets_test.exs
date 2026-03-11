defmodule Symphony.FeedbackAssetsTest do
  use ExUnit.Case, async: false

  alias Plug.Conn
  alias Symphony.{FeedbackAssets, Issue}

  setup do
    ref = make_ref()

    {:ok, _pid} =
      Plug.Cowboy.http(__MODULE__.Router, [], ip: {127, 0, 0, 1}, port: 0, ref: ref)

    port = :ranch.get_port(ref)

    on_exit(fn ->
      Plug.Cowboy.shutdown(ref)
      Application.delete_env(:symphony, :linear_upload_regex)
    end)

    %{base_url: "http://127.0.0.1:#{port}"}
  end

  test "extract_references finds linear upload urls in description and comments" do
    issue = %Issue{
      identifier: "SBO-1",
      description: "See screenshot https://uploads.linear.app/a/b/c",
      comments: [
        %{body: "Another one ![img](https://uploads.linear.app/d/e/f)"},
        %{body: "duplicate https://uploads.linear.app/a/b/c"}
      ]
    }

    refs = FeedbackAssets.extract_references(issue)

    assert Enum.map(refs, & &1.url) == [
             "https://uploads.linear.app/a/b/c",
             "https://uploads.linear.app/d/e/f"
           ]
  end

  test "sync keeps going when referenced uploads cannot be downloaded", %{base_url: _base_url} do
    workspace =
      Path.join(System.tmp_dir!(), "feedback-assets-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    issue = %Issue{
      identifier: "SBO-1",
      description: "See screenshot https://uploads.linear.app/a/b/c.png",
      comments: [%{body: "Another https://uploads.linear.app/d/e/f.jpg"}]
    }

    config = %Symphony.Config{tracker_api_key: "linear-key"}

    updated = FeedbackAssets.sync(issue, config, workspace)

    assert updated.feedback_assets == []
    assert updated.feedback_assets_text == ""
  end

  test "sync downloads supported feedback assets into the workspace", %{base_url: base_url} do
    Application.put_env(
      :symphony,
      :linear_upload_regex,
      ~r{#{Regex.escape(base_url)}/[^\s<>)\]]+}
    )

    workspace =
      Path.join(System.tmp_dir!(), "feedback-assets-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    issue = %Issue{
      identifier: "SBO-1",
      description: "See screenshot #{base_url}/image.png",
      comments: [%{body: "Another #{base_url}/image.jpg"}]
    }

    config = %Symphony.Config{tracker_api_key: "linear-key"}

    updated = FeedbackAssets.sync(issue, config, workspace)

    assert length(updated.feedback_assets) == 2
    assert Enum.all?(updated.feedback_assets, &File.exists?(&1.path))
    assert Enum.any?(updated.feedback_assets, &String.ends_with?(&1.relative_path, ".png"))
    assert Enum.any?(updated.feedback_assets, &String.ends_with?(&1.relative_path, ".jpg"))
    assert updated.feedback_assets_text =~ "Screenshot feedback files downloaded into the workspace:"
    assert updated.feedback_assets_text =~ "from description"
    assert updated.feedback_assets_text =~ "from comment"
  end

  test "sync skips downloads when the api key is missing", %{base_url: base_url} do
    Application.put_env(
      :symphony,
      :linear_upload_regex,
      ~r{#{Regex.escape(base_url)}/[^\s<>)\]]+}
    )

    workspace =
      Path.join(System.tmp_dir!(), "feedback-assets-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    issue = %Issue{identifier: "SBO-1", description: "See #{base_url}/image.png"}
    updated = FeedbackAssets.sync(issue, %Symphony.Config{tracker_api_key: nil}, workspace)

    assert updated.feedback_assets == []
    assert updated.feedback_assets_text == ""
  end

  defmodule Router do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/image.png" do
      conn
      |> Conn.put_resp_header("content-type", "image/png")
      |> Conn.send_resp(200, "png-binary")
    end

    get "/image.jpg" do
      conn
      |> Conn.put_resp_header("content-type", "image/jpeg")
      |> Conn.send_resp(200, "jpg-binary")
    end
  end
end
