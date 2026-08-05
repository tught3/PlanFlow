import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

import aitDevtools from "@apps-in-toss/devtools/unplugin";

// https://vite.dev/config/
export default defineConfig({
  plugins: [aitDevtools.vite(), react()],
})
