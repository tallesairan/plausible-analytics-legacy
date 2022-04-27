defmodule PlausibleWeb.Api.ExternalController do
  use PlausibleWeb, :controller
  require Logger

  def event(conn, _params) do
    params = parse_body(conn)
    Sentry.Context.set_extra_context(%{request: params})

    case create_event(conn, params) do
      :ok ->
        conn |> put_status(202) |> text("ok")

      {:error, errors} ->
        conn |> put_status(400) |> json(%{errors: errors})
    end
  end

  def error(conn, _params) do
    Sentry.capture_message("JS snippet error")
    send_resp(conn, 200, "")
  end

  def health(conn, _params) do
    postgres_health =
      case Ecto.Adapters.SQL.query(Plausible.Repo, "SELECT 1", []) do
        {:ok, _} -> "ok"
        e -> "error: #{inspect(e)}"
      end

    clickhouse_health =
      case Ecto.Adapters.SQL.query(Plausible.ClickhouseRepo, "SELECT 1", []) do
        {:ok, _} -> "ok"
        e -> "error: #{inspect(e)}"
      end

    status =
      case {postgres_health, clickhouse_health} do
        {"ok", "ok"} -> 200
        _ -> 500
      end

    put_status(conn, status)
    |> json(%{
      postgres: postgres_health,
      clickhouse: clickhouse_health
    })
  end

  defp parse_user_agent(conn) do
    user_agent = Plug.Conn.get_req_header(conn, "user-agent") |> List.first()

    if user_agent do
      res =
        Cachex.fetch(:user_agents, user_agent, fn ua ->
          UAInspector.parse(ua)
        end)

      case res do
        {:ok, user_agent} -> user_agent
        {:commit, user_agent} -> user_agent
        _ -> nil
      end
    end
  end

  @no_domain_error {:error, %{domain: ["can't be blank"]}}

  defp create_event(conn, params) do
    params = %{
      "name" => params["n"] || params["name"],
      "url" => params["u"] || params["url"],
      "referrer" => params["r"] || params["referrer"],
      "domain" => params["d"] || params["domain"],
      "screen_width" => params["w"] || params["screen_width"],
      "hash_mode" => params["h"] || params["hashMode"],
      "meta" => parse_meta(params)
    }

    ua = parse_user_agent(conn)

    if is_bot?(ua) || params["domain"] in Application.get_env(:plausible, :domain_blacklist) do
      :ok
    else
      uri = params["url"] && URI.parse(params["url"])
      host = if uri && uri.host == "", do: "(none)", else: uri && uri.host
      query = decode_query_params(uri)

      ref = parse_referrer(uri, params["referrer"])
      country_code = visitor_country(conn)
      salts = Plausible.Session.Salts.fetch()

      event_attrs = %{
        timestamp: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second),
        name: params["name"],
        hostname: strip_www(host),
        pathname: get_pathname(uri, params["hash_mode"]),
        referrer_source: get_referrer_source(query, ref),
        referrer: clean_referrer(ref),
        utm_medium: query["utm_medium"],
        utm_source: query["utm_source"],
        utm_campaign: query["utm_campaign"],
        country_code: country_code,
        operating_system: ua && os_name(ua),
        operating_system_version: ua && os_version(ua),
        browser: ua && browser_name(ua),
        browser_version: ua && browser_version(ua),
        screen_size: calculate_screen_size(params["screen_width"]),
        "meta.key": Map.keys(params["meta"]),
        "meta.value": Map.values(params["meta"]) |> Enum.map(&Kernel.to_string/1)
      }

      Enum.reduce_while(get_domains(params, uri), @no_domain_error, fn domain, _res ->
        user_id = generate_user_id(conn, domain, event_attrs[:hostname], salts[:current])

        previous_user_id =
          salts[:previous] &&
            generate_user_id(conn, domain, event_attrs[:hostname], salts[:previous])

        changeset =
          event_attrs
          |> Map.merge(%{domain: domain, user_id: user_id})
          |> Plausible.ClickhouseEvent.new()

        if changeset.valid? do
          event = Ecto.Changeset.apply_changes(changeset)
          session_id = Plausible.Session.Store.on_event(event, previous_user_id)

          event
          |> Map.put(:session_id, session_id)
          |> Plausible.Event.WriteBuffer.insert()

          {:cont, :ok}
        else
          errors = Ecto.Changeset.traverse_errors(changeset, &encode_error/1)
          {:halt, {:error, errors}}
        end
      end)
    end
  end

  # https://hexdocs.pm/ecto/Ecto.Changeset.html#traverse_errors/2-examples
  defp encode_error({msg, opts}) do
    Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end

  defp is_bot?(%UAInspector.Result.Bot{}), do: true

  defp is_bot?(%UAInspector.Result{client: %UAInspector.Result.Client{name: "Headless Chrome"}}),
    do: true

  defp is_bot?(_), do: false

  defp parse_meta(params) do
    raw_meta = params["m"] || params["meta"] || params["p"] || params["props"]

    with raw_json when not is_nil(raw_meta) <- raw_meta,
         {:ok, parsed_json} when is_map(parsed_json) <- Jason.decode(raw_json),
         :ok <- validate_custom_props(parsed_json) do
      parsed_json
    else
      _ -> %{}
    end
  end

  defp validate_custom_props(props) do
    is_valid =
      Enum.all?(props, fn {_key, val} ->
        !is_list(val)
      end)

    if is_valid, do: :ok, else: :invalid_props
  end

  defp get_domains(params, uri) do
    if params["domain"] do
      String.split(params["domain"], ",")
      |> Enum.map(&String.trim/1)
      |> Enum.map(&strip_www/1)
    else
      List.wrap(strip_www(uri && uri.host))
    end
  end

  defp get_pathname(nil, _), do: "/"

  defp get_pathname(uri, hash_mode) do
    pathname =
      (uri.path || "/")
      |> URI.decode()

    if hash_mode && uri.fragment do
      pathname <> "#" <> URI.decode(uri.fragment)
    else
      pathname
    end
  end

  defp visitor_country(conn) do
    result =
      PlausibleWeb.RemoteIp.get(conn)
      |> Geolix.lookup()

    get_in(result, [:country, :country, :iso_code])
  end

  defp parse_referrer(_, nil), do: nil

  defp parse_referrer(uri, referrer_str) do
    referrer_uri = URI.parse(referrer_str)

    if strip_www(referrer_uri.host) !== strip_www(uri.host) && referrer_uri.host !== "localhost" do
      RefInspector.parse(referrer_str)
    end
  end

  defp generate_user_id(conn, domain, hostname, salt) do
    user_agent = List.first(Plug.Conn.get_req_header(conn, "user-agent")) || ""
    ip_address = PlausibleWeb.RemoteIp.get(conn)
    root_domain = get_root_domain(hostname)

    if domain && root_domain do
      SipHash.hash!(salt, user_agent <> ip_address <> domain <> root_domain)
    end
  end

  defp get_root_domain(nil), do: "(none)"

  defp get_root_domain(hostname) do
    case PublicSuffix.registrable_domain(hostname) do
      domain when is_binary(domain) -> domain
      _ -> hostname
    end
  end

  defp calculate_screen_size(nil), do: nil
  defp calculate_screen_size(width) when width < 576, do: "Mobile"
  defp calculate_screen_size(width) when width < 992, do: "Tablet"
  defp calculate_screen_size(width) when width < 1440, do: "Laptop"
  defp calculate_screen_size(width) when width >= 1440, do: "Desktop"

  defp clean_referrer(nil), do: nil

  defp clean_referrer(ref) do
    uri = URI.parse(ref.referer)

    if right_uri?(uri) do
      host = String.replace_prefix(uri.host, "www.", "")
      path = uri.path || ""
      host <> String.trim_trailing(path, "/")
    end
  end

  defp parse_body(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        Jason.decode!(body)

      params ->
        params
    end
  end

  defp strip_www(nil), do: nil

  defp strip_www(hostname) do
    String.replace_prefix(hostname, "www.", "")
  end

  defp browser_name(ua) do
    case ua.client do
      :unknown -> ""
      %UAInspector.Result.Client{name: "Mobile Safari"} -> "Safari"
      %UAInspector.Result.Client{name: "Chrome Mobile"} -> "Chrome"
      %UAInspector.Result.Client{name: "Chrome Mobile iOS"} -> "Chrome"
      %UAInspector.Result.Client{name: "Firefox Mobile"} -> "Firefox"
      %UAInspector.Result.Client{name: "Firefox Mobile iOS"} -> "Firefox"
      %UAInspector.Result.Client{name: "Opera Mobile"} -> "Opera"
      %UAInspector.Result.Client{name: "Chrome Webview"} -> "Mobile App"
      %UAInspector.Result.Client{type: "mobile app"} -> "Mobile App"
      client -> client.name
    end
  end

  defp major_minor(:unknown), do: ""

  defp major_minor(version) do
    version
    |> String.split(".")
    |> Enum.take(2)
    |> Enum.join(".")
  end

  defp browser_version(ua) do
    case ua.client do
      :unknown -> ""
      %UAInspector.Result.Client{type: "mobile app"} -> ""
      client -> major_minor(client.version)
    end
  end

  defp os_name(ua) do
    case ua.os do
      :unknown -> ""
      os -> os.name
    end
  end

  defp os_version(ua) do
    case ua.os do
      :unknown -> ""
      os -> major_minor(os.version)
    end
  end

  defp get_referrer_source(query, ref) do
    source = query["utm_source"] || query["source"] || query["ref"]
    source || get_source_from_referrer(ref)
  end

  defp get_source_from_referrer(nil), do: nil

  defp get_source_from_referrer(ref) do
    case ref.source do
      :unknown ->
        clean_uri(ref.referer)

      source ->
        source
    end
  end

  defp clean_uri(uri) do
    uri = URI.parse(String.trim(uri))

    if right_uri?(uri) do
      String.replace_leading(uri.host, "www.", "")
    end
  end

  defp right_uri?(%URI{host: nil}), do: false

  defp right_uri?(%URI{host: host, scheme: scheme})
       when scheme in ["http", "https"] and byte_size(host) > 0,
       do: true

  defp right_uri?(_), do: false

  defp decode_query_params(nil), do: nil
  defp decode_query_params(%URI{query: nil}), do: nil

  defp decode_query_params(%URI{query: query_part}) do
    try do
      URI.decode_query(query_part)
    rescue
      _ -> nil
    end
  end
end
