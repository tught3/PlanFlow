import { defineConfig } from '@apps-in-toss/web-framework/config';

export default defineConfig({
  appName: 'planflowa',
  brand: {
    primaryColor: '#1E3A5F', // 출처: PlanFlow lib/core/theme.dart PlanFlowColors.primary
  },
  permissions: [],
  webBundleDir: 'dist',
});
