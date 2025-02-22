defmodule HostCore.Actors.ActorModule do
  @moduledoc """
  The actor module is a layer of encapsulation around a single instance of a running WebAssembly module. Each
  actor module carries with it the information used to start it, as well as runtime-augmented metadata like
  its instance ID (a guid).

  You should not start actors manually using `start_link`, and instead use `HostCore.Actors.ActorSupervisor.start_actor_from_bindle/4`
  or `HostCore.Actors.ActorSupervisor.start_actor_from_oci/4`
  """

  # Do not automatically restart this process unless it stopped due to crash
  use GenServer, restart: :transient

  alias HostCore.Actors.ActorRpcSupervisor
  alias HostCore.Claims.Manager, as: ClaimsManager
  alias HostCore.CloudEvent
  alias HostCore.ControlInterface.LatticeServer
  alias HostCore.Policy.Manager, as: PolicyManager
  alias HostCore.Vhost.VirtualHost
  alias HostCore.WasmCloud.Native

  require OpenTelemetry.Tracer, as: Tracer

  @chunk_threshold 900 * 1024
  @thirty_seconds 30_000
  @perform_invocation "perform_invocation"
  @rpc_event_prefix "wasmbus.rpcevt"

  require Logger

  defmodule State do
    @moduledoc """
    Represents the running state of an actor module. This struct is kept as the contents of an agent and is _not_
    used as the raw value of the GenServer state.
    """

    defstruct [
      # NIF reference wrapper for the compiled module/component managed by the wasmCloud Rust crate
      :actor_reference,
      # PID of the HostCore.WasmCloud.Runtime.Server GenServer that provides access to the underlying runtime
      :runtime_pid,
      :instance,
      :instance_id,
      :annotations,
      :api_version,
      :invocation,
      :claims,
      :ociref,
      :healthy,
      :parent_span,
      :host_id,
      :lattice_prefix
    ]
  end

  defmodule Invocation do
    @moduledoc false
    defstruct [:operation, :payload]
  end

  @doc """
  Starts the Actor module with a map containing the following fields:

  ```
  %{
      claims: claims,
      bytes: bytes,
      oci: oci,
      annotations: annotations,
      host_id: host_id
  }
  ```

  * `claims` - A map containing claims extracted from the wasm file
  * `bytes` - The raw bytes of the signed module
  * `oci` - An oci (or bindle) reference accompanying this actor
  * `annotations` - Annotations map used for tagging instances for wadm
  * `host_id` - The virtual host on which the actor will be started. Must be a running host.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def current_invocation(pid) do
    GenServer.call(pid, :get_invocation)
  end

  def api_version(pid) do
    GenServer.call(pid, :get_api_ver)
  end

  def claims(pid) do
    if Process.alive?(pid) do
      GenServer.call(pid, :get_claims)
    else
      %{}
    end
  end

  def ociref(pid) do
    if Process.alive?(pid) do
      GenServer.call(pid, :get_ociref)
    else
      "n/a"
    end
  end

  def instance_id(pid) do
    if Process.alive?(pid) do
      GenServer.call(pid, :get_instance_id)
    else
      "??"
    end
  end

  def annotations(pid) do
    if Process.alive?(pid) do
      GenServer.call(pid, :get_annotations)
    else
      %{}
    end
  end

  def full_state(pid) do
    if Process.alive?(pid) do
      GenServer.call(pid, :get_full_state)
    else
      %{}
    end
  end

  @doc """
  Halts the actor module corresponding to the supplied process ID. This will attempt a graceful termination
  and will try and emit an `actor_stopped` event.
  """
  def halt(pid) do
    if Process.alive?(pid), do: GenServer.call(pid, :halt_and_cleanup)
  end

  @doc """
  Triggers a live update, replacing the WebAssembly module of the process at the given pid with the raw
  bytes supplied. This is a blocking operation on the actor's mailbox, so no messages/invocations will be
  handled while the module swap takes place
  """
  def live_update(config, pid, bytes, claims, oci, span_ctx \\ nil) do
    GenServer.call(pid, {:live_update, config, bytes, claims, oci, span_ctx}, @thirty_seconds)
  end

  @doc """
  GenServer callback initializing the actor module.
  """
  @impl true
  def init(%{
        claims: claims,
        bytes: bytes,
        oci: oci,
        annotations: annotations,
        host_id: host_id
      }) do
    lattice_prefix = VirtualHost.get_lattice_for_host(host_id)

    case start_actor(lattice_prefix, host_id, claims, bytes, oci, annotations) do
      {:ok, agent} ->
        {:ok, agent, {:continue, :register_actor}}

      {:error, _e} ->
        # Actor should stop with no adverse effects on the supervisor
        :ignore
    end
  end

  @impl true
  def handle_continue(:register_actor, agent) do
    agent_state = Agent.get(agent, fn contents -> contents end)
    Registry.register(Registry.ActorRegistry, agent_state.claims.public_key, agent_state.host_id)
    {:noreply, agent}
  end

  @impl GenServer
  def handle_info(_, state) do
    # drain unmatched messages to avoid box overflow
    {:noreply, state}
  end

  def handle_call({:live_update, config, bytes, claims, oci, span_ctx}, _from, agent) do
    ctx = span_ctx || OpenTelemetry.Ctx.new()

    Tracer.with_span ctx, "Perform Live Update", kind: :server do
      Tracer.set_attribute("public_key", claims.public_key)
      Tracer.set_attribute("actor_ref", oci)

      Logger.debug("Actor #{claims.public_key} performing live update",
        actor_id: claims.public_key,
        oci_ref: oci
      )

      instance_id = Agent.get(agent, fn content -> content.instance_id end)
      Tracer.set_attribute("instance_id", instance_id)

      runtime_pid = Agent.get(agent, fn a -> a.runtime_pid end)

      # TODO: do we need to make a call into the runtime to "un"compile the previous
      # actor reference's bytes, e.g. `uncache_actor(old_aref)`
      case HostCore.WasmCloud.Runtime.Server.precompile_actor(runtime_pid, bytes) do
        {:ok, aref} ->
          publish_actor_updated(
            config.lattice_prefix,
            config.host_key,
            claims.public_key,
            claims.revision,
            instance_id
          )

          Agent.update(agent, fn state -> %State{state | actor_reference: aref} end)

          Logger.info("Actor #{claims.public_key} live update complete",
            actor_id: claims.public_key,
            oci_ref: oci
          )

        {:error, e} ->
          error_msg =
            "Failed to live update #{claims.public_key}, couldn't replace wasm module: #{inspect(e)}"

          Logger.error(error_msg)

          Tracer.set_status(:error, error_msg)

          publish_actor_update_failed(
            config.lattice_prefix,
            config.host_key,
            claims.public_key,
            claims.revision,
            instance_id,
            inspect(e)
          )
      end

      # failing to update won't crash the process, it emits errors and stays on the old version
      {:reply, :ok, agent}
    end

    # tracer span
  end

  # A handful of individual query calls to pull information from the agent state

  def handle_call(:get_full_state, _from, agent) do
    {:reply, Agent.get(agent, fn content -> content end), agent}
  end

  def handle_call(:get_api_ver, _from, agent) do
    {:reply, Agent.get(agent, fn content -> content.api_version end), agent}
  end

  def handle_call(:get_claims, _from, agent) do
    {:reply, Agent.get(agent, fn content -> content.claims end), agent}
  end

  def handle_call(:get_instance_id, _from, agent) do
    {:reply, Agent.get(agent, fn content -> content.instance_id end), agent}
  end

  def handle_call(:get_annotations, _from, agent) do
    {:reply, Agent.get(agent, fn content -> content.annotations end), agent}
  end

  def handle_call(:get_ociref, _from, agent) do
    {:reply, Agent.get(agent, fn content -> content.ociref end), agent}
  end

  @impl true
  def handle_call(:get_invocation, _from, agent) do
    {:reply, Agent.get(agent, fn content -> content.invocation end), agent}
  end

  @impl true
  def handle_call(:halt_and_cleanup, _from, agent) do
    # Add cleanup if necessary here...
    contents = Agent.get(agent, fn content -> content end)
    public_key = contents.claims.public_key
    name = contents.claims.name
    instance_id = contents.instance_id
    lattice_prefix = contents.lattice_prefix
    host_id = contents.host_id
    annotations = contents.annotations

    Logger.debug("Terminating instance of actor #{public_key} (#{name})",
      actor_id: public_key
    )

    publish_actor_stopped(host_id, lattice_prefix, public_key, instance_id, annotations)

    # PRO TIP - if you return :normal here as the stop reason, the GenServer will NOT auto-terminate
    # all of its children. If you want all children established via start_link to be terminated here,
    # you -have- to use :shutdown as the reason.
    # That's right, the stop reason :normal automatically results in orphaned processes.
    {:stop, :shutdown, :ok, agent}
  end

  # Triggered when the actor RPC server receives an inbound message on wasmbus.rpc.{lattice}.{actor}
  @impl true
  def handle_call(
        {
          :handle_incoming_rpc,
          %{
            body: body,
            reply_to: _reply_to,
            topic: topic
          } = msg
        },
        _from,
        agent
      ) do
    reconstitute_trace_context(Map.get(msg, :headers))

    Tracer.with_span "Handle Invocation", kind: :server do
      Logger.debug("Actor received invocation on #{topic}")

      %{
        instance_id: iid,
        host_id: host_id,
        claims: %{public_key: public_key}
      } = Agent.get(agent, & &1)

      config = VirtualHost.config(host_id)
      cluster_issuers = config.cluster_issuers
      lattice_prefix = config.lattice_prefix

      Tracer.set_attribute("instance_id", iid)
      Tracer.set_attribute("public_key", public_key)

      token = %{
        iid: iid,
        invocation: nil,
        inv_res: nil,
        anti_forgery: false,
        source_target: false,
        policy: false
      }

      {token, ir} =
        token
        |> unpack_body(body)
        |> validate_anti_forgery(body, cluster_issuers)
        |> validate_invocation_source_target(agent)
        |> policy_check(agent)
        |> check_dechunk_inv()
        |> perform_runtime_invocation(agent)

      publish_invocation_result(host_id, lattice_prefix, token.invocation, ir)

      {:reply, {:ok, ir |> Msgpax.pack!() |> IO.iodata_to_binary()}, agent}
    end
  end

  defp unpack_body(%{} = token, body) do
    case Msgpax.unpack(body) do
      {:ok, inv} ->
        Tracer.set_attribute("invocation_id", inv["id"])

        %{token | invocation: inv}

      _ ->
        Tracer.set_status(:error, "Failed to deserialize msgpack invocation")

        %{
          token
          | inv_res: %{
              msg: <<>>,
              invocation_id: "",
              error: "Failed to deserialize invocation",
              instance_id: token.iid
            }
        }
    end
  end

  defp validate_anti_forgery(%{invocation: nil} = token, _body, _issuers) do
    %{token | anti_forgery: false}
  end

  defp validate_anti_forgery(%{invocation: inv} = token, body, issuers) do
    case Native.validate_antiforgery(
           body,
           issuers
         ) do
      {:error, msg} ->
        Logger.error("Invocation failed anti-forgery validation check: #{msg}",
          invocation_id: inv["id"]
        )

        Tracer.set_status(:error, "Anti-forgery check failed #{msg}")

        %{
          token
          | anti_forgery: false,
            inv_res: %{
              msg: <<>>,
              invocation_id: token.invocation["id"],
              error: "Anti-forgery check failed: #{msg}",
              instance_id: token.iid
            }
        }

      _ ->
        %{token | anti_forgery: true}
    end
  end

  defp validate_invocation_source_target(%{anti_forgery: false} = token, _agent) do
    %{token | source_target: false}
  end

  defp validate_invocation_source_target(
         %{
           anti_forgery: true,
           invocation: %{
             "origin" => %{
               "link_name" => nil,
               "contract_id" => nil
             }
           }
         } = token,
         _agent
       ) do
    %{token | source_target: true}
  end

  defp validate_invocation_source_target(
         %{
           anti_forgery: true,
           invocation: %{
             "origin" => %{
               "link_name" => "",
               "contract_id" => ""
             }
           }
         } = token,
         _agent
       ) do
    %{token | source_target: true}
  end

  defp validate_invocation_source_target(
         %{
           anti_forgery: true,
           invocation: %{
             "origin" => %{
               "link_name" => _,
               "contract_id" => contract_id
             }
           }
         } = token,
         agent
       ) do
    caps = Agent.get(agent, fn contents -> contents.claims.caps end)
    res = Enum.member?(caps, contract_id)

    if res do
      %{token | source_target: true}
    else
      %{
        token
        | source_target: false,
          inv_res: %{
            msg: <<>>,
            invocation_id: token.invocation["id"],
            error: "Invocation source does not have the required capability claim #{contract_id}",
            instance_id: token.iid
          }
      }
    end
  end

  defp policy_check(%{source_target: false} = token, _agent) do
    %{token | policy: false}
  end

  defp policy_check(%{source_target: true} = token, agent) do
    lattice_prefix = Agent.get(agent, fn contents -> contents.lattice_prefix end)
    host_id = Agent.get(agent, fn contents -> contents.host_id end)
    source = token.invocation["origin"]
    target = token.invocation["target"]

    decision =
      with {:ok, {pid, _}} <- VirtualHost.lookup(host_id),
           config <- VirtualHost.config(pid),
           labels <- VirtualHost.labels(pid),
           {:ok, _topic} <- PolicyManager.policy_topic(config),
           {:ok, source_claims} <-
             ClaimsManager.lookup_claims(lattice_prefix, source["public_key"]),
           {:ok, target_claims} <-
             ClaimsManager.lookup_claims(lattice_prefix, target["public_key"]) do
        expired =
          case source_claims[:exp] do
            nil -> false
            # If the current UTC time is greater than the expiration time, it's expired
            time -> DateTime.utc_now() > time
          end

        if expired do
          %{permitted: false}
        else
          PolicyManager.evaluate_action(
            config,
            labels,
            %{
              publicKey: source["public_key"],
              contractId: source["contract_id"],
              linkName: source["link_name"],
              capabilities: source_claims[:caps],
              issuer: source_claims[:iss],
              issuedOn: source_claims[:iat],
              expiresAt: source_claims[:exp],
              expired: expired
            },
            %{
              publicKey: target["public_key"],
              contractId: target["contract_id"],
              linkName: target["link_name"],
              issuer: target_claims[:iss]
            },
            @perform_invocation
          )
        end
      else
        :policy_eval_disabled -> %{permitted: true}
        # Failed to get host info or check claims for source or target, denying
        :error -> %{permitted: false}
      end

    case decision do
      %{permitted: false} ->
        %{
          token
          | policy: false,
            inv_res: %{
              msg: <<>>,
              invocation_id: token.invocation["id"],
              error: "Policy evaluation rejected invocation attempt",
              instance_id: token.iid
            }
        }

      _ ->
        %{token | policy: true}
    end
  end

  defp reconstitute_trace_context(headers) when is_list(headers) do
    if Enum.any?(headers, fn {k, _v} -> k == "traceparent" end) do
      :otel_propagator_text_map.extract(headers)
    else
      OpenTelemetry.Ctx.clear()
    end
  end

  defp reconstitute_trace_context(_) do
    # If there is a nil for the headers, then clear context
    OpenTelemetry.Ctx.clear()
  end

  # Invocation responses are stored in the chunked object store with a `-r` appended
  # to the end of the invocation ID
  defp chunk_inv_response(
         %{
           msg: response,
           invocation_id: invid,
           instance_id: _iid
         } = map
       )
       when byte_size(response) > @chunk_threshold do
    case Native.chunk_inv("#{invid}-r", response) do
      :ok -> %{map | msg: <<>>}
      _ -> map
    end
  end

  defp chunk_inv_response(map), do: map

  defp check_dechunk_inv(%{policy: false} = token), do: token

  defp check_dechunk_inv(%{policy: true} = token) do
    content_length = Map.get(token.invocation, "content_length", 0)
    bytes = Map.get(token.invocation, "msg", <<>>)

    bytes =
      if content_length > byte_size(bytes) do
        Logger.debug(
          "Dechunking #{content_length} from object store for #{token.invocation["id"]}",
          invocation_id: token.invocation["id"]
        )

        case Native.dechunk_inv(token.invocation["id"]) do
          {:ok, bytes} ->
            bytes

          {:error, e} ->
            Logger.error("Failed to dechunk invocation:  #{inspect(e)}")

            <<>>
        end
      else
        bytes
      end

    inv = token.invocation
    inv = Map.put(inv, "msg", bytes)
    %{token | invocation: inv}
  end

  defp start_actor(lattice_prefix, host_id, claims, bytes, oci, annotations) do
    Logger.metadata(
      lattice_prefix: lattice_prefix,
      host_id: host_id,
      actor_id: claims.public_key,
      oci_ref: oci
    )

    Logger.info("Starting actor #{claims.public_key}")

    {:ok, {pid, _}} = HostCore.Vhost.VirtualHost.lookup(host_id)
    runtime_pid = HostCore.Vhost.VirtualHost.get_runtime(pid)

    case HostCore.WasmCloud.Runtime.Server.precompile_actor(runtime_pid, bytes) do
      {:ok, aref} ->
        iid = UUID.uuid4()
        ClaimsManager.put_claims(host_id, lattice_prefix, claims)
        ActorRpcSupervisor.start_or_reuse_consumer_supervisor(lattice_prefix, claims)
        publish_oci_map(host_id, lattice_prefix, oci, claims.public_key)
        publish_actor_started(host_id, lattice_prefix, claims, "n/a", iid, oci, annotations)

        Agent.start_link(fn ->
          %State{
            actor_reference: aref,
            ociref: oci,
            runtime_pid: runtime_pid,
            claims: claims,
            instance_id: iid,
            healthy: false,
            annotations: annotations,
            lattice_prefix: lattice_prefix,
            host_id: host_id
          }
        end)

      {:error, e} ->
        Logger.error("Failed to start actor: #{inspect(e)}", actor_id: claims.public_key)

        LatticeServer.publish_actor_start_failed(
          host_id,
          lattice_prefix,
          claims.public_key,
          inspect(e)
        )

        {:error, e}
    end
  end

  defp perform_runtime_invocation(%{policy: false} = token, _agent), do: {token, token.inv_res}

  defp perform_runtime_invocation(token, agent) do
    operation = token.invocation["operation"]
    payload = IO.iodata_to_binary(token.invocation["msg"])
    runtime_pid = Agent.get(agent, fn a -> a.runtime_pid end)
    aref = Agent.get(agent, fn a -> a.actor_reference end)

    call_context =
      Tracer.current_span_ctx()
      |> :erlang.term_to_binary()

    ir =
      case HostCore.WasmCloud.Runtime.Server.invoke_actor(
             runtime_pid,
             aref,
             operation,
             payload,
             call_context
           ) do
        {:ok, msg} ->
          chunk_inv_response(%{
            msg: msg,
            invocation_id: token.invocation["id"],
            instance_id: token.iid,
            content_length: byte_size(msg)
          })

        {:error, msg} ->
          %{
            msg: <<>>,
            error: msg,
            invocation_id: token.invocation["id"],
            instance_id: token.iid,
            content_length: 0
          }
      end

    {token, ir}
  end

  def publish_oci_map(_host_id, _lattice_prefix, "", _pk) do
    # No Op
  end

  def publish_oci_map(_host_id, _lattice_prefix, nil, _pk) do
    # No Op
  end

  def publish_oci_map(host_id, lattice_prefix, oci, pk) do
    HostCore.Refmaps.Manager.put_refmap(host_id, lattice_prefix, oci, pk)
  end

  @spec publish_invocation_result(
          host_id :: String.t(),
          lattice_prefix :: String.t(),
          inv :: map(),
          inv_r :: map()
        ) :: :ok
  defp publish_invocation_result(host_id, lattice_prefix, inv, inv_r) do
    origin = inv["origin"]
    target = inv["target"]

    evt_type =
      if Map.get(inv_r, :error) == nil do
        "invocation_succeeded"
      else
        "invocation_failed"
      end

    %{
      source: %{
        public_key: origin["public_key"],
        contract_id: Map.get(origin, "contract_id"),
        link_name: Map.get(origin, "link_name")
      },
      dest: %{
        public_key: target["public_key"],
        contract_id: Map.get(target, "contract_id"),
        link_name: Map.get(target, "link_name")
      },
      operation: inv["operation"],
      bytes: Map.get(inv, "msg", "") |> IO.iodata_to_binary() |> byte_size()
    }
    |> CloudEvent.new(evt_type, host_id)
    |> CloudEvent.publish(
      lattice_prefix,
      @rpc_event_prefix
    )
  end

  def publish_actor_started(
        host_id,
        lattice_prefix,
        claims,
        api_version,
        instance_id,
        oci,
        annotations
      ) do
    %{
      public_key: claims.public_key,
      image_ref: oci,
      api_version: api_version,
      instance_id: instance_id,
      annotations: annotations,
      claims: %{
        call_alias: claims.call_alias,
        caps: claims.caps,
        issuer: claims.issuer,
        tags: claims.tags,
        name: claims.name,
        version: claims.version,
        revision: claims.revision,
        not_before_human: claims.not_before_human,
        expires_human: claims.expires_human
      }
    }
    |> CloudEvent.new("actor_started", host_id)
    |> CloudEvent.publish(lattice_prefix)

    # topic = "#{@event_prefix}.#{lattice_prefix}"

    # HostCore.Nats.safe_pub(HostCore.Nats.control_connection(lattice_prefix), topic, msg)
  end

  def publish_actor_updated(prefix, host_id, actor_pk, revision, instance_id) do
    %{
      public_key: actor_pk,
      revision: revision,
      instance_id: instance_id
    }
    |> CloudEvent.new("actor_updated", host_id)
    |> CloudEvent.publish(prefix)
  end

  def publish_actor_update_failed(prefix, host_id, actor_pk, revision, instance_id, reason) do
    %{
      public_key: actor_pk,
      revision: revision,
      instance_id: instance_id,
      reason: reason
    }
    |> CloudEvent.new("actor_update_failed", host_id)
    |> CloudEvent.publish(prefix)
  end

  def publish_actor_stopped(host_id, lattice_prefix, actor_pk, instance_id, annotations) do
    %{
      public_key: actor_pk,
      instance_id: instance_id,
      annotations: annotations
    }
    |> CloudEvent.new("actor_stopped", host_id)
    |> CloudEvent.publish(lattice_prefix)
  end
end
