<script lang="ts">
  import Button from '../atoms/Button.svelte';
  import Card from '../atoms/Card.svelte';

  export let count: number;
  export let onStartAll: () => void;
  export let onStopAll: () => void;
</script>

<Card padding="md">
  <div class="flex flex-wrap items-center justify-between gap-4">
    <h3 class="text-lg font-semibold text-gray-900">
      Group Control ({count} selected)
    </h3>

    <div class="flex gap-2">
      <Button variant="primary" size="md" on:click={onStartAll}>
        ▶️ Start All
      </Button>
      <Button variant="secondary" size="md" on:click={onStopAll}>
        ⏹ Stop All
      </Button>
    </div>
  </div>
</Card>
