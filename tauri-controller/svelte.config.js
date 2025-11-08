import { vitePreprocess } from '@sveltejs/vite-plugin-svelte'
import { preprocessMeltUI, sequence } from '@melt-ui/pp'

export default {
  preprocess: sequence([vitePreprocess(), preprocessMeltUI()]),
}
