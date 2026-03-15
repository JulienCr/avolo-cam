<script lang="ts">
  type BadgeStatus = 'live' | 'ready' | 'offline' | 'pending' | 'warning';

  let { status }: { status: BadgeStatus } = $props();

  const config: Record<BadgeStatus, { label: string; classes: string }> = {
    live: { label: 'LIVE', classes: 'bg-green-500/20 text-green-400 border-green-500/30' },
    ready: { label: 'READY', classes: 'bg-blue-500/20 text-blue-400 border-blue-500/30' },
    offline: { label: 'OFFLINE', classes: 'bg-neutral-500/20 text-neutral-400 border-neutral-500/30' },
    pending: { label: 'PENDING', classes: 'bg-amber-500/20 text-amber-400 border-amber-500/30' },
    warning: { label: 'WARNING', classes: 'bg-red-500/20 text-red-400 border-red-500/30' },
  };

  let cfg = $derived(config[status]);
</script>

<span class="inline-flex items-center rounded-sm px-1.5 py-0 text-[9px] font-semibold uppercase tracking-wide border {cfg.classes}">
  {cfg.label}
</span>
