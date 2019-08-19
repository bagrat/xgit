defmodule Xgit.Util.TrailingHashDevice do
  @moduledoc ~S"""
  Creates an `iodevice` process that supports git file formats with a trailing
  SHA-1 hash.

  When reading, the trailing 20 bytes are interpreted as a SHA-1 hash of the
  remaining file contents and can be verified using the `valid_hash?/1` function.

  This is an admittedly minimal implementation; just enough is implemented to
  allow Xgit's index file parser to do its work.
  """
  use GenServer

  require Logger

  @doc ~S"""
  Creates an IO device that reads a file with trailing hash.

  Unlike `File.open/2` and `File.open/3`, no options or function are
  accepted.

  This device can be passed to `IO.binread/2`.

  ## Return Value

  `{:ok, pid}` where `pid` points to an IO device process.

  `{:ok, reason}` if the file could not be opened. See `File.open/2` for
  possible values for `reason`.
  """
  @spec open_file(path :: Path.t()) :: {:ok, pid} | {:error, File.posix()}
  def open_file(path) when is_binary(path),
    do: GenServer.start_link(__MODULE__, {:file, path})

  @doc ~S"""
  Creates an IO device that reads a string with trailing hash.

  This is intended mostly for internal testing purposes.

  Unlike `StringIO.open/2` and `StringIO.open/3`, no options or function are
  accepted.

  This device can be passed to `IO.binread/2`.

  ## Return Value

  `{:ok, pid}` where `pid` points to an IO device process.
  """
  @spec open_string(s :: binary) :: {:ok, pid}
  def open_string(s) when is_binary(s) and byte_size(s) >= 20,
    do: GenServer.start_link(__MODULE__, {:string, s})

  @doc ~S"""
  Returns `true` if this is process is an `TrailingHashDevice` instance.

  Note the difference between this function and `valid_hash?/1`.
  """
  @spec valid?(v :: any) :: boolean
  def valid?(v) when is_pid(v),
    do: GenServer.call(v, :valid_trailing_hash_read_device?) == :valid_trailing_hash_read_device

  def valid?(_), do: false

  @doc ~S"""
  Returns `true` if the hash at the end of the file matches the hash
  generated while reading the file.

  Should only be called once and only once when the entire file (sans SHA-1 hash)
  has been read.

  ## Return Values

  `true` or `false` if the SHA-1 hash was found and was valid (or not).

  `:too_soon` if called before the SHA-1 hash is expected.

  `:already_called` if called a second (or successive) time.
  """
  @spec valid_hash?(io_device :: pid) :: boolean
  def valid_hash?(io_device) when is_pid(io_device),
    do: GenServer.call(io_device, :valid_hash?)

  @impl true
  def init({:file, path}) do
    with {:ok, %{size: size}} <- File.stat(path, time: :posix),
         {:ok, pid} when is_pid(pid) <- File.open(path) do
      {:ok, %{iodevice: pid, remaining_bytes: size - 20, crypto: :crypto.hash_init(:sha)}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  def init({:string, s}) do
    {:ok, pid} = StringIO.open(s)
    {:ok, %{iodevice: pid, remaining_bytes: byte_size(s) - 20, crypto: :crypto.hash_init(:sha)}}
  end

  @impl true
  def handle_info({:io_request, from, reply_as, req}, state) do
    state = io_request(from, reply_as, req, state)
    {:noreply, state}
  end

  def handle_info({:file_request, from, reply_as, req}, state) do
    state = file_request(from, reply_as, req, state)
    {:noreply, state}
  end

  def handle_info(message, state) do
    Logger.warn("TrailingHashDevice received unexpected message #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def handle_call(:valid_trailing_hash_read_device?, _from_, state),
    do: {:reply, :valid_trailing_hash_read_device, state}

  def handle_call(:valid_hash?, _from, %{remaining_bytes: 0, crypto: :done} = state),
    do: {:reply, :already_called, state}

  def handle_call(
        :valid_hash?,
        _from,
        %{iodevice: iodevice, remaining_bytes: remaining_bytes, crypto: crypto} = state
      )
      when remaining_bytes <= 0 do
    actual_hash = :crypto.hash_final(crypto)
    hash_from_file = IO.binread(iodevice, 20)

    {:reply, actual_hash == hash_from_file, %{state | crypto: :done}}
  end

  def handle_call(:valid_hash?, _from, state), do: {:reply, :too_soon, state}

  def handle_call(request, _from, state) do
    Logger.warn("TrailingHashDevice received unexpected call #{inspect(request)}")
    {:reply, :unknown_message, state}
  end

  defp io_request(from, reply_as, req, state) do
    {reply, state} = io_request(req, state)
    send(from, {:io_reply, reply_as, reply})
    state
  end

  defp io_request({:get_chars, :"", count}, %{remaining_bytes: remaining_bytes} = state)
       when remaining_bytes <= 0 and is_integer(count) and count >= 0 do
    {:eof, state}
  end

  defp io_request({:get_chars, :"", 0}, state), do: {"", state}

  defp io_request(
         {:get_chars, :"", count},
         %{iodevice: iodevice, remaining_bytes: remaining_bytes, crypto: crypto} = state
       )
       when is_integer(count) and count > 0 do
    data = IO.binread(iodevice, min(remaining_bytes, count))

    if is_binary(data) do
      crypto = :crypto.hash_update(crypto, data)
      {data, %{state | remaining_bytes: remaining_bytes - byte_size(data), crypto: crypto}}
    else
      {data, state}
    end
  end

  defp io_request(request, state) do
    Logger.warn("TrailingHashDevice received unexpected iorequest #{inspect(request)}")
    {{:error, :request}, state}
  end

  defp file_request(from, reply_as, req, state) do
    {reply, state} = file_request(req, state)
    send(from, {:file_reply, reply_as, reply})
    state
  end

  defp file_request(:close, %{iodevice: iodevice} = state),
    do: {File.close(iodevice), %{state | iodevice: nil}}

  defp file_request(request, state) do
    Logger.warn("TrailingHashDevice received unexpected file_request #{inspect(request)}")
    {{:error, :request}, state}
  end
end