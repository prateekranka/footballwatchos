import { test } from '@e2e-dev/mobile';
import { expect } from 'e2e';
import { explore, fixture, layout, openFresh, tab } from './support/football-ui.ts';

test('QA fixture and layout menus have captured options', async ui => {
  const { app, screen } = ui;
  await openFresh(ui);
  await layout(ui, 'Standard');
  await screen.getByTestId('qa-data-fixture').tap();
  for (const option of ['Demo data', 'Worst case', 'Empty', 'One', '1,000 rows']) {
    await expect(screen.getByRole('button', option, { exact: true })).toBeVisible();
  }
  await app.screenshot('qa-fixture-menu');
  await screen.getByRole('button', 'Empty', { exact: true }).tap();
  await expect(screen.getByText('Sessions on this iPhone, 0', { exact: true })).toBeVisible();
  await screen.getByTestId('qa-layout-stress').tap();
  for (const option of ['Standard', '320 pt width', '200% text', '200% text at 320 pt', 'Right to left', 'Animations off']) {
    await expect(screen.getByRole('button', option, { exact: true })).toBeVisible();
  }
  await app.screenshot('qa-layout-menu');
  await screen.getByRole('button', 'Standard', { exact: true }).tap();
  await tab(screen, 'Sessions').tap();
});

test('light and dark palettes keep primary actions and quality labels legible', async ui => {
  const { app, screen } = ui;
  await openFresh(ui);
  await layout(ui, 'Standard');
  await screen.getByRole('button', /^Appearance,/).getByText(/^(System|Light|Dark)$/).tap();
  await screen.getByRole('button', 'System', { exact: true }).tap();
  await fixture(ui, 'Worst case');
  await ui.device.setAppearance('light');
  await expect(screen.getByTestId('add-session')).toBeVisible();
  await app.screenshot('palette-light-worst-sessions');
  await ui.device.setAppearance('dark');
  await app.screenshot('palette-dark-worst-sessions');
  await screen.getByRole('scroll-view').first().swipe({ direction: 'down' });
  await screen.scrollUntilVisible(screen.getByRole('button', 'See all', { exact: true }), { direction: 'down' });
  await screen.getByRole('button', 'See all', { exact: true }).tap();
  const interrupted = screen.getByRole('button', /11-a-side.*Watch recording/).first();
  await screen.scrollUntilVisible(interrupted, { direction: 'down' });
  await interrupted.tap();
  await expect(screen.getByText('11-a-side · Watch recording', { exact: true })).toBeVisible();
  await explore(ui, 'Recording quality');
  await expect(screen.getByText(/Watch storage failed during recording/)).toBeVisible();
  await app.screenshot('palette-dark-interrupted-quality');
  await ui.device.setAppearance('light');
  await app.screenshot('palette-light-interrupted-quality');
});
