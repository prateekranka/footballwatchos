import { test } from '@e2e-dev/mobile';
import { expect } from 'e2e';
import { addManual, explore, fixture, latest, openFresh } from './support/football-ui.ts';

test('manual reports show missing sensors and export and delete stay local', async ui => {
  const { app, screen } = ui;
  await openFresh(ui);
  await fixture(ui, 'Empty');
  await addManual(ui, 'Training', '90');
  await latest(ui, 'Training.*Manual log');
  await app.screenshot('manual-overview-top');
  await expect(screen.getByText('Only the date, duration, and type were entered. No sensor readings were recorded.', { exact: true })).toBeVisible();
  await explore(ui, 'Heart rate');
  await expect(screen.getByText('No heart-rate readings', { exact: true })).toBeVisible();
  await app.screenshot('manual-heart-rate-empty');
  await app.back();
  await explore(ui, 'Movement');
  await app.screenshot('manual-movement-empty');
  await app.back();
  await explore(ui, 'Details');
  await expect(screen.getByText('Entered by you', { exact: true })).toBeVisible();
  await app.screenshot('manual-details-top');
  const exportButton = screen.getByRole('button', 'Prepare exact export', { exact: true });
  await screen.scrollUntilVisible(exportButton, { direction: 'down' });
  await app.screenshot('manual-details-actions');
  await exportButton.tap();
  await expect(screen.getByRole('button', 'Share verified package', { exact: true })).toBeVisible();
  await app.screenshot('manual-details-export-ready');
  await screen.getByRole('button', 'Delete iPhone copy', { exact: true }).tap();
  await app.screenshot('delete-confirmation');
  const cancel = screen.getByRole('button', 'Cancel', { exact: true });
  if (await cancel.isVisible()) await cancel.tap();
  else await screen.getByTestId('PopoverDismissRegion').tap();
  await expect(screen.getByRole('button', 'Share verified package', { exact: true })).toBeVisible();
  await screen.getByRole('button', 'Delete iPhone copy', { exact: true }).tap();
  await screen.getByRole('button', 'Delete iPhone copy', { exact: true }).last().tap();
  await app.screenshot('session-after-delete');
  await app.restart();
  await expect(screen.getByText('No sessions yet', { exact: true })).toBeVisible();
});

test('manual quality never claims a sensor recording occurred', async ui => {
  const { app, screen } = ui;
  await openFresh(ui);
  await fixture(ui, 'Empty');
  await addManual(ui, 'Training', '90');
  await latest(ui, 'Training.*Manual log');
  await explore(ui, 'Recording quality');
  await app.screenshot('manual-quality');
  await expect(screen.getByText('This recording started and finished normally.', { exact: true })).toBeHidden();
  await expect(screen.getByText('Manual log', { exact: true })).toBeVisible();
});

test('recorded zero distance and a 15-second session stay distinct from missing data', async ui => {
  const { app, screen } = ui;
  await openFresh(ui);
  await fixture(ui, 'Worst case');
  await app.screenshot('worst-case-sessions');
  await latest(ui, 'Football.*Watch recording');
  await app.screenshot('short-zero-distance-overview');
  await expect(screen.getByText('15 s', { exact: true }).first()).toBeVisible();
  await expect(screen.getByText('0.0 km', { exact: true })).toBeVisible();
});
