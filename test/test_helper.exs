ExUnit.start()

# Start a test registry to avoid atom exhaustion when generating queue names
{:ok, _} = Registry.start_link(keys: :unique, name: Tasque.TestRegistry)
