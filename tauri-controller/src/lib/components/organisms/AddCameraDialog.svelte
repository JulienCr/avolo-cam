<script lang="ts">
  import Modal from './Modal.svelte';
  import FormRow from '../molecules/FormRow.svelte';
  import Input from '../atoms/Input.svelte';
  import Button from '../atoms/Button.svelte';
  import type { Writable } from 'svelte/store';

  export let open: Writable<boolean>;
  export let onAdd: (ip: string, port: number, token: string) => Promise<void>;

  let ip = '';
  let port = 8888;
  let token = '';
  let submitting = false;

  async function handleSubmit() {
    try {
      submitting = true;
      await onAdd(ip, port, token);
      // Reset form
      ip = '';
      port = 8888;
      token = '';
      open.set(false);
    } catch (e) {
      alert(`Failed to add camera: ${e}`);
    } finally {
      submitting = false;
    }
  }
</script>

<Modal {open} title="Add Camera Manually" size="md">
  <form on:submit|preventDefault={handleSubmit} class="flex flex-col gap-4">
    <FormRow label="IP Address" layout="vertical" required>
      <Input type="text" bind:value={ip} placeholder="192.168.1.100" required />
    </FormRow>

    <FormRow label="Port" layout="vertical" required>
      <Input type="number" bind:value={port} min={1} max={65535} required />
    </FormRow>

    <FormRow label="Bearer Token" layout="vertical" required>
      <Input type="text" bind:value={token} placeholder="Token from iPhone" required />
    </FormRow>

    <div class="mt-4 flex gap-2">
      <Button type="submit" variant="primary" size="md" disabled={submitting} class="flex-1">
        {submitting ? 'Adding...' : 'Add'}
      </Button>
      <Button type="button" variant="secondary" size="md" on:click={() => open.set(false)}>
        Cancel
      </Button>
    </div>
  </form>
</Modal>
