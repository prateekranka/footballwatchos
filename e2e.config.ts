import type { E2EConfig } from 'e2e';
import { mobile } from '@e2e-dev/mobile';
import { mobileTools } from '@e2e-dev/mobile/tools';
import { chatgpt } from 'e2e/oauth/chatgpt';

const iphone = mobile({
  platform: 'ios',
  device: process.env.FP_SIMULATOR_UDID ?? '7AEFF457-CBA5-4485-A13D-896E75169E07',
  session: 'football-pro-ui',
  settle: 250,
  transition: 800,
});

export default {
  tests: 'Tests/**/*.e2e.ts',
  workers: 1,
  retries: 0,
  timeout: 300_000,
  launchTimeout: 180_000,
  output: '.scratch/evidence/football-break-ui/20261006T202104Z.4TnHSq/e2e',
  video: 'on',
  agents: {
    default: {
      model: chatgpt('gpt-6-luna'),
      providerOptions: { openai: { reasoningEffort: 'max', serviceTier: 'fast' } },
      tools: mobileTools(iphone),
      maxSteps: 25,
      maxModelCalls: 25,
      context: 'Football Performance is a native iPhone companion. Manual logs contain only a date, duration, and football type. Watch recordings carry sensor evidence. Do not connect services or change credentials. Synthetic QA fixtures are labelled and are not real recordings.',
      system: 'Check the actual screen and its values. Test empty, one-session, multiple-session, invalid-input, and missing-evidence states. Record only issues the visible screen proves.',
    },
  },
  targets: [{
    name: 'iphone',
    engine: iphone,
    app: {
      bundleId: 'com.prateekranka.footballperformance',
      appPath: process.env.FP_APP_PATH,
      launchArguments: ['-FP_UI_QA', 'YES'],
    },
  }],
} satisfies E2EConfig;
