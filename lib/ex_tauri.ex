defmodule ExTauri do
  @latest_version "2.5.0"

  use Application
  require Logger
  @doc false
  def start(_, _) do
    unless Application.get_env(:ex_tauri, :version) do
      Logger.warning("""
      tauri version is not configured. Please set it in your config files:

          config :ex_tauri, :version, "#{latest_version()}"
      """)
    end

    Supervisor.start_link([], strategy: :one_for_one)
  end

  @doc """
  Returns the latest version of tauri available.
  """
  def latest_version, do: @latest_version

  def install(extra_args \\ []) do
    app_name = Application.get_env(:ex_tauri, :app_name, "Phoenix Application")
    window_title = Application.get_env(:ex_tauri, :window_title, app_name)
    scheme = Application.get_env(:ex_tauri, :scheme) || "http"
    host = Application.get_env(:ex_tauri, :host) || raise "Expected :host to be configured"
    port = Application.get_env(:ex_tauri, :port) || raise "Expected :port to be configured"
    version = Application.get_env(:ex_tauri, :version) || latest_version()
    fullscreen = Application.get_env(:ex_tauri, :fullscreen, false)
    height = Application.get_env(:ex_tauri, :height, 600)
    width = Application.get_env(:ex_tauri, :width, 800)
    resize = Application.get_env(:ex_tauri, :resize, true)
    installation_path = installation_path()
    File.mkdir_p!(installation_path)

    opts = [
      cd: installation_path,
      into: IO.stream(:stdio, :line),
      stderr_to_stdout: true
    ]

    if System.find_executable(cargo_tauri_path()) == nil do
      System.cmd("cargo", ["install", "tauri-cli@#{version}", "--root", "."], opts)
    end

    args =
      [
        "init",
        "--app-name",
        app_name |> String.replace("\s", "") |> Macro.underscore(),
        "--window-title",
        window_title,
        "--force",
        "--dev-url",
        "#{scheme}://#{host}:#{port}",
        "--frontend-dist",
        "#{scheme}://#{host}:#{port}",
        "--directory",
        File.cwd!(),
        "--tauri-path",
        File.cwd!(),
        "--before-dev-command",
        "",
        "--before-build-command",
        ""
      ] ++ extra_args

    opts = [
      into: IO.stream(:stdio, :line),
      stderr_to_stdout: true
    ]

    case System.cmd(cargo_tauri_path(), args, opts) do
      {_, 0} -> :ok
      {_, status} -> Mix.raise("tauri unable to install. exited with status #{status}")
    end

    # Override Cargo.toml to use app_name and set proper crates so they are not dependent on folders
    path = Path.join([File.cwd!(), "src-tauri", "Cargo.toml"])
    File.write!(path, cargo_toml(app_name))

    # Override main.rs to set proper startup sequence
    path = Path.join([File.cwd!(), "src-tauri", "src", "main.rs"])
    File.write!(path, main_src())

    # TODO remove this when possible, for some reason it's failing at the moment
    File.cp!(
      Path.join([File.cwd!(), "src-tauri", "build.rs"]),
      Path.join([File.cwd!(), "src-tauri", "src", "build.rs"])
    )

    # Add side car and required configuration to tauri.conf.json
    Path.join([File.cwd!(), "src-tauri", "tauri.conf.json"])
    |> File.read!()
    |> Jason.decode!()
    |> then(fn content ->
      content
      |> put_in(["productName"], app_name)
      |> put_in(["bundle", "externalBin"], ["../burrito_out/desktop"])
      |> put_in(
        ["identifier"],
        "you.app.#{app_name |> String.replace("\s", "") |> Macro.underscore() |> String.replace("_", "-")}"
      )
      |> put_in(["app", "windows"], [
        %{
          title: window_title,
          fullscreen: fullscreen,
          width: width,
          height: height,
          resizable: resize
        }
      ])
    end)
    |> Jason.encode!(pretty: true)
    |> then(&File.write!(Path.join([File.cwd!(), "src-tauri", "tauri.conf.json"]), &1))

    # Add side car capabilities to capabilities/default.json
    Path.join([File.cwd!(), "src-tauri", "capabilities", "default.json"])
    |> File.read!()
    |> Jason.decode!()
    |> then(fn content ->
      content
      |> update_in(["permissions"], fn permissions ->
        permissions ++
          [
            %{
              identifier: "shell:allow-execute",
              allow: [
                %{
                  args: ["start"],
                  name: "../burrito_out/desktop",
                  sidecar: true
                }
              ]
            }
          ]
      end)
      |> update_in(["permissions"], &(&1 ++ ["shell:allow-execute"]))
    end)
    |> Jason.encode!(pretty: true)
    |> then(
      &File.write!(Path.join([File.cwd!(), "src-tauri", "capabilities", "default.json"]), &1)
    )
  end

  @doc """
  Returns the path to the executable.

  The executable may not be available if it was not yet installed.
  """
  def installation_path do
    Application.get_env(:ex_tauri, :path) ||
      if Code.ensure_loaded?(Mix.Project) do
        Path.join(Path.dirname(Mix.Project.build_path()), "_tauri")
      else
        Path.expand("_build/_tauri")
      end
  end

  @doc """
  Installs, if not available, and then runs `tailwind`.

  Returns the same as `run/2`.
  """
  def install_and_run(args) do
    unless File.exists?(installation_path()) do
      install(args)
    end

    run(args)
  end

  @doc """
  Runs the given command with `args`.

  The given args will be appended to the configured args.
  The task output will be streamed directly to stdio. It
  returns the status of the underlying call.
  """
  def run(args) when is_list(args) do
    wrap()

    # Set proper environment variables for tauri
    System.put_env("TAURI_CLI_NO_DEV_SERVER_WAIT", "true")

    opts = [
      cd: Path.join(File.cwd!(), "src-tauri"),
      into: IO.stream(:stdio, :line),
      stderr_to_stdout: true
    ]

    System.cmd(cargo_tauri_path(), args, opts)
  end

  defp wrap() do
    File.rm_rf!("burrito_out/")

    case :os.type() do
      {:win32, _} ->
        File.rm_rf!(Path.join([Path.expand("~"), ".burrito"]))

      {:unix, :darwin} ->
        File.rm_rf!(Path.join([Path.expand("~"), "Library", "Application Support", ".burrito"]))

      {:unix, :linux} ->
        File.rm_rf!(Path.join([Path.expand("~"), "local", "share", ".burrito"]))
    end

    get_in(Mix.Project.config(), [:releases, :desktop]) ||
      raise "expected a burrito release configured for the app :desktop in your mix.exs"

    Mix.Task.run("release", ["desktop", "--overwrite", "--quiet", "--force"])

    triplet =
      System.cmd("rustc", ["-Vv"])
      |> elem(0)
      |> then(&Regex.run(~r/host: (.*)/, &1))
      |> Enum.at(1)

    File.cp!(
      "burrito_out/desktop_#{triplet}",
      "burrito_out/desktop-#{triplet}"
    )

    :ok
  end

  defp cargo_tauri_path() do
    Path.join([installation_path(), "bin", "cargo-tauri"])
  end

  defp cargo_toml(app_name) do
    app_name = app_name |> String.replace("\s", "") |> Macro.underscore()

    """
    [package]
    name = "#{app_name}"
    version = "0.1.0"
    default-run = "#{app_name}"
    edition = "2018"
    build = "src/build.rs"
    description = ""

    [build-dependencies]
    tauri-build = { version = "2.2.0", features = [] }

    [dependencies]
    serde_json = "1.0"
    serde = { version = "1.0", features = ["derive"] }
    tauri = { version = "2.5.1", features = [] }
    log = { version = "0.4.27", features = ["serde"] }
    tauri-plugin-log = { version = "2.4.0", features = ["colored"] }
    tauri-plugin-shell = "2.2.1"

    [features]
    # this feature is used for production builds or when `devPath` points to the filesystem and the built-in dev server is disabled.
    # If you use cargo directly instead of tauri's cli you can use this feature flag to switch between tauri's `dev` and `build` modes.
    # DO NOT REMOVE!!
    custom-protocol = [ "tauri/custom-protocol" ]
    """
  end

  defp main_src() do
    """
    // Prevents additional console window on Windows in release, DO NOT REMOVE!!
    #![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
    use tauri::api::process::{Command, CommandEvent};

    fn main() {
    tauri::Builder::default()
            .setup(|app| {
                let sidecar_command = app.shell().sidecar("desktop").unwrap().args(["start"]);
                let (mut rx, mut _child) = sidecar_command.spawn().unwrap();

                tauri::async_runtime::spawn(async move {
                    while let Some(event) = rx.recv().await {
                        if let CommandEvent::Stdout(line_bytes) = event {
                            let line = String::from_utf8_lossy(&line_bytes);
                            println!("{}", line);
                        }
                    }
                });

                Ok(())
            })
            .plugin(tauri_plugin_shell::init())
            .run(tauri::generate_context!())
            .expect("error while running tauri application");
    }
    """
  end
end
