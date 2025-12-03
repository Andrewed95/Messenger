// LI: Custom Layout with Sync Button
// Extends the default react-admin Layout to add LI-specific functionality
// to the AppBar, including the database sync button.
//
// This file exists to minimize changes to App.tsx while adding LI features.

import { AppBar, Layout, LayoutProps, TitlePortal, UserMenu } from "react-admin";

import { LISyncButton } from "./LISyncButton";

/**
 * LI: Custom AppBar with Sync Button
 *
 * Adds a sync button next to the user menu that allows
 * LI admins to trigger database synchronization.
 */
const LIAppBar = () => (
  <AppBar
    toolbar={
      <>
        {/* LI: Sync button for database synchronization */}
        <LISyncButton />
        {/* Default user menu */}
        <UserMenu />
      </>
    }
  >
    <TitlePortal />
  </AppBar>
);

/**
 * LI: Custom Layout
 *
 * Uses the default react-admin Layout but with our custom AppBar
 * that includes the sync button.
 */
export const LILayout = (props: LayoutProps) => (
  <Layout {...props} appBar={LIAppBar} />
);

export default LILayout;
