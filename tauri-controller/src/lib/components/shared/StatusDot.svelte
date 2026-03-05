<script lang="ts">
  type Status = 'connected' | 'disconnected' | 'connecting';

  let { status = 'disconnected' }: { status: Status } = $props();

  const colors: Record<Status, string> = {
    connected: 'bg-green-500',
    disconnected: 'bg-red-500',
    connecting: 'bg-yellow-500 animate-pulse',
  };
</script>

<span class="inline-block h-2 w-2 rounded-full {colors[status]}" title={status}></span>
