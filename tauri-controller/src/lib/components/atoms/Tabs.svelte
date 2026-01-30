<script lang="ts">
  export let tabs: Array<{ id: string; label: string; icon?: string }>;
  export let activeTab: string;
  export let onChange: (id: string) => void;
</script>

<div class="border-b border-gray-200 dark:border-gray-700">
  <nav class="flex -mb-px space-x-4" aria-label="Tabs">
    {#each tabs as tab}
      <button
        on:click={() => onChange(tab.id)}
        class="whitespace-nowrap py-3 px-1 border-b-2 font-medium text-sm transition-colors {activeTab === tab.id
          ? 'border-blue-500 text-blue-600 dark:text-blue-400'
          : 'border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300 dark:text-gray-400 dark:hover:text-gray-300'}"
        aria-current={activeTab === tab.id ? 'page' : undefined}
      >
        {#if tab.icon}
          <span class="mr-2">{tab.icon}</span>
        {/if}
        {tab.label}
      </button>
    {/each}
  </nav>
</div>

