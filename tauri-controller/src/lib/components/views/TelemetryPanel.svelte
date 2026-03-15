<script lang="ts">
  import type { Telemetry } from '$lib/types/camera';
  import { formatBattery, formatTemperature, formatBitrate } from '$lib/utils/format';

  let { telemetry }: { telemetry: Telemetry | null | undefined } = $props();
</script>

{#if telemetry}
  <div class="flex flex-col gap-2 p-2 rounded-lg border border-border bg-card">
    <span class="text-[10px] font-semibold uppercase tracking-wider text-muted-foreground">Telemetry</span>
    <div class="grid grid-cols-2 gap-2">
      <!-- Battery -->
      <div class="flex flex-col gap-0.5 p-1.5 rounded bg-surface/50">
        <span class="text-[9px] uppercase tracking-wider text-muted-foreground">Battery</span>
        <span class="text-sm font-semibold tabular-nums text-foreground">{formatBattery(telemetry.battery)}</span>
        {#if telemetry.charging_state}
          <span class="text-[9px] text-green-400">Charging</span>
        {/if}
      </div>

      <!-- Temperature -->
      <div class="flex flex-col gap-0.5 p-1.5 rounded bg-surface/50">
        <span class="text-[9px] uppercase tracking-wider text-muted-foreground">Temperature</span>
        <span class="text-sm font-semibold tabular-nums {telemetry.temp_c > 40 ? 'text-orange-400' : 'text-foreground'}">{formatTemperature(telemetry.temp_c)}</span>
      </div>

      <!-- CPU -->
      <div class="flex flex-col gap-0.5 p-1.5 rounded bg-surface/50">
        <span class="text-[9px] uppercase tracking-wider text-muted-foreground">CPU</span>
        <span class="text-sm font-semibold tabular-nums {telemetry.cpu_usage > 85 ? 'text-orange-400' : 'text-foreground'}">{telemetry.cpu_usage.toFixed(0)}%</span>
      </div>

      <!-- Bitrate -->
      <div class="flex flex-col gap-0.5 p-1.5 rounded bg-surface/50">
        <span class="text-[9px] uppercase tracking-wider text-muted-foreground">Bitrate</span>
        <span class="text-sm font-semibold tabular-nums text-foreground">{formatBitrate(telemetry.bitrate)} Mbps</span>
      </div>

      <!-- Dropped Frames -->
      {#if telemetry.dropped_frames && telemetry.dropped_frames > 0}
        <div class="flex flex-col gap-0.5 p-1.5 rounded bg-surface/50 col-span-2">
          <span class="text-[9px] uppercase tracking-wider text-muted-foreground">Dropped Frames</span>
          <span class="text-sm font-semibold tabular-nums text-red-400">{telemetry.dropped_frames}</span>
        </div>
      {/if}
    </div>
  </div>
{:else}
  <div class="flex items-center justify-center p-4 rounded-lg border border-border border-dashed bg-card">
    <span class="text-[10px] text-muted-foreground italic">No telemetry data</span>
  </div>
{/if}
