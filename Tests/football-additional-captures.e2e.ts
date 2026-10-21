import { test } from '@e2e-dev/mobile';
import { expect } from 'e2e';
import { dismissPopover, explore, fixture, latest, layout, openFresh, tab, type FootballUI } from './support/football-ui.ts';

async function appearance(ui: FootballUI, value: 'System' | 'Light' | 'Dark') {
  await tab(ui.screen, 'Settings').tap();
  await ui.screen.scrollUntilVisible(ui.screen.getByRole('button', /^Appearance,/), { direction: 'up' });
  await ui.screen.getByRole('button', /^Appearance,/).getByText(/^(System|Light|Dark)$/).tap();
  await ui.screen.getByRole('button', value, { exact: true }).tap();
}

test('future end time is rejected through the native calendar', async ui => {
  const { app, screen } = ui;
  await openFresh(ui);
  await layout(ui, 'Standard');
  await fixture(ui, 'Empty');
  await screen.getByTestId('add-session').tap();
  await expect(screen.getByTestId('session-duration')).toHaveValue('45');
  await screen.getByTestId('session-start').getByRole('button', /^\d+ \w+ \d{4}$/).tap();
  const today = screen.getByText(/^Today,/);
  await today.tap();
  await expect(today).toBeSelected();
  await app.screenshot('calendar-today-selected');
  await dismissPopover(screen, today);
  await expect(screen.getByTestId('DatePicker.Show')).toBeHidden();
  await screen.getByTestId('save-session').tap();
  await expect(screen.getByTestId('session-validation').first()).toContainText('Choose a start time that puts the end of the session in the past.');
  await app.screenshot('future-end-validation');
  await screen.getByRole('button', 'Cancel', { exact: true }).tap();
  await tab(screen, 'Settings').tap();
  await expect(screen.getByText('Sessions on this iPhone, 0', { exact: true })).toBeVisible();
  await app.restart();
  await tab(screen, 'Settings').tap();
  await expect(screen.getByText('Sessions on this iPhone, 0', { exact: true })).toBeVisible();
});

test('standard quality, dark overview, and QA settings have direct screen evidence', async ui => {
  const { app, screen } = ui;
  await openFresh(ui);
  await layout(ui, 'Standard');
  await fixture(ui, 'Demo data');
  await appearance(ui, 'Light');
  await expect(screen.getByTestId('qa-data-fixture')).toBeVisible();
  await expect(screen.getByTestId('qa-layout-stress')).toBeVisible();
  await app.screenshot('qa-settings-main-direct');
  await tab(screen, 'Sessions').tap();
  await latest(ui, 'Football.*Watch recording');
  await explore(ui, 'Recording quality');
  await expect(screen.getByText('Completed', { exact: true })).toBeVisible();
  await expect(screen.getByText(/Foreground Core Motion fallback/).first()).toBeVisible();
  await app.screenshot('completed-quality-standard-direct-top');
  await screen.scrollUntilVisible(screen.getByText('Health save outcome', { exact: true }), { direction: 'down' });
  await app.screenshot('completed-quality-standard-direct-lower');
  await app.restart();
  await appearance(ui, 'Dark');
  await tab(screen, 'Sessions').tap();
  await latest(ui, 'Football.*Watch recording');
  await expect(screen.getByText('Football · Watch recording', { exact: true }).first()).toBeVisible();
  await app.screenshot('overview-dark-ltr-direct-top');
  await screen.getByRole('scroll-view').first().swipe({ direction: 'down' });
  await app.screenshot('overview-dark-ltr-direct-lower');
  await app.restart();
  await appearance(ui, 'System');
});
