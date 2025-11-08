# Migration Guide & QA Checklist

## Migration Steps

### 1. Pre-Migration Backup
```bash
# Backup existing App.svelte (already done)
# Original file backed up to: src/App.svelte.backup
```

### 2. Dependencies Installed
All required dependencies have been installed:
- ✅ Tailwind CSS + PostCSS + Autoprefixer
- ✅ Melt UI (`@melt-ui/svelte`, `@melt-ui/pp`)
- ✅ TypeScript + Svelte Preprocess
- ✅ TypeScript config for Svelte

### 3. Configuration Files
The following configuration files have been created/updated:
- ✅ `tailwind.config.js` - Design tokens, color palette, spacing, shadows
- ✅ `postcss.config.js` - PostCSS with Tailwind & Autoprefixer
- ✅ `tsconfig.json` - TypeScript configuration
- ✅ `tsconfig.node.json` - Node-specific TS config
- ✅ `svelte.config.js` - Svelte preprocessor config
- ✅ `src/app.css` - Tailwind directives
- ✅ `index.html` - Updated to reference main.ts

### 4. New Directory Structure
```
src/
├── lib/
│   ├── components/
│   │   ├── atoms/           # 8 components
│   │   ├── molecules/       # 6 components
│   │   └── organisms/       # 9 components
│   ├── stores/              # 4 stores (cameras, ui, settings, profiles)
│   ├── types/               # 3 type definition files
│   └── utils/               # 3 utility files
├── App.svelte               # Refactored main app
├── app.css                  # Tailwind imports
└── main.ts                  # Entry point (renamed from main.js)
```

### 5. Build & Test

Run the following commands to verify the migration:

```bash
cd /home/user/avolo-cam/tauri-controller

# Install dependencies (already done)
# npm install

# Run development server
npm run dev

# Run Tauri in development mode
npm run tauri:dev

# Build for production
npm run build
```

### 6. Known Breaking Changes

1. **TypeScript Migration**
   - `main.js` → `main.ts`
   - All new components are TypeScript-enabled
   - Type-safe API calls via `lib/utils/api.ts`

2. **State Management**
   - Migrated from local component state to Svelte stores
   - Import stores from `$lib/stores/*`

3. **Component Architecture**
   - 1807-line monolithic App.svelte → Modular component system
   - Components follow atomic design pattern

4. **Styling**
   - Vanilla CSS → Tailwind CSS
   - Design tokens centralized in `tailwind.config.js`
   - No more inline `style=` attributes

---

## QA Checklist

### ✅ Accessibility (WCAG AA)

- [ ] **Keyboard Navigation**
  - [ ] Tab through all interactive elements
  - [ ] Press Enter/Space on buttons
  - [ ] Use arrow keys in sliders
  - [ ] Escape closes dialogs

- [ ] **Focus States**
  - [ ] Visible focus rings on all interactive elements
  - [ ] Focus trapped in open dialogs
  - [ ] Focus returns to trigger element when dialog closes

- [ ] **ARIA Labels**
  - [ ] All buttons have accessible labels
  - [ ] Form inputs have associated labels
  - [ ] Dialogs have titles
  - [ ] Status messages are announced

- [ ] **Screen Reader Testing**
  - [ ] Test with VoiceOver (macOS) or NVDA (Windows)
  - [ ] Camera state announced correctly
  - [ ] Settings changes announced
  - [ ] Error messages readable

---

### ✅ Responsiveness

- [ ] **Mobile (320px - 767px)**
  - [ ] Header stacks vertically
  - [ ] Camera grid: 1 column
  - [ ] Settings form: 1 column
  - [ ] Buttons stack vertically
  - [ ] Dialog width: 90vw

- [ ] **Tablet (768px - 1023px)**
  - [ ] Camera grid: 2 columns
  - [ ] Settings form: 2 columns
  - [ ] Group controls horizontal layout

- [ ] **Desktop (1024px+)**
  - [ ] Camera grid: 3 columns
  - [ ] Full horizontal layout
  - [ ] Max width: 1400px

- [ ] **Test Breakpoints**
  - [ ] 320px (iPhone SE)
  - [ ] 375px (iPhone 12/13)
  - [ ] 768px (iPad)
  - [ ] 1024px (Desktop)
  - [ ] 1440px (Wide desktop)

---

### ✅ Dark Mode

- [ ] **Toggle Dark Mode**
  - [ ] Use browser/OS preference
  - [ ] Add class `dark` to `<html>` element

- [ ] **Component Testing**
  - [ ] Cards readable in dark mode
  - [ ] Buttons have dark variants
  - [ ] Inputs have proper contrast
  - [ ] Sliders visible
  - [ ] Text readable (contrast >= 4.5:1)

---

### ✅ Functional Testing

- [ ] **Camera Management**
  - [ ] Discover cameras via mDNS
  - [ ] Add camera manually (IP, port, token)
  - [ ] Remove camera (with confirmation)
  - [ ] Refresh camera list

- [ ] **Streaming**
  - [ ] Start single stream
  - [ ] Stop single stream
  - [ ] Force IDR keyframe
  - [ ] Group start (multiple cameras)
  - [ ] Group stop (multiple cameras)

- [ ] **Camera Settings**
  - [ ] Open settings dialog
  - [ ] Change stream settings (resolution, FPS, bitrate, codec)
  - [ ] Adjust white balance (temperature, tint)
  - [ ] Measure white balance (auto calibrate)
  - [ ] Adjust exposure (ISO, shutter speed)
  - [ ] Switch camera position (front/back)
  - [ ] Select lens (ultra-wide, wide, telephoto)
  - [ ] Auto/manual mode toggles work
  - [ ] Settings debounced (300ms delay)

- [ ] **Profiles**
  - [ ] Save profile from current settings
  - [ ] Apply profile to selected cameras
  - [ ] Delete profile (with confirmation)
  - [ ] Profile list updates immediately

- [ ] **Selection**
  - [ ] Select individual cameras (checkbox)
  - [ ] Group control bar appears when >0 selected
  - [ ] Selection persists across refreshes (in session)
  - [ ] Deselect when camera removed

---

### ✅ Visual Testing

- [ ] **Sliders**
  - [ ] Visible track and handle
  - [ ] Min/max labels present
  - [ ] Current value displayed
  - [ ] Disabled state (opacity 40%)
  - [ ] Height: at least `h-8` (2rem)

- [ ] **Spacing**
  - [ ] Consistent gaps between elements
  - [ ] Padding inside cards (p-4, p-5, p-6)
  - [ ] Margins between sections (mb-4, mb-6)

- [ ] **Typography**
  - [ ] Headings: font-semibold, font-bold
  - [ ] Body: font-normal
  - [ ] Monospace for telemetry values
  - [ ] Units aligned (e.g., "5000K", "1/100")

- [ ] **Colors**
  - [ ] Primary: #667eea (purple/indigo)
  - [ ] Secondary: #764ba2 (darker purple)
  - [ ] Success: green-500
  - [ ] Danger: red-500
  - [ ] Gray scale for neutral elements

- [ ] **Shadows**
  - [ ] Cards: shadow-card
  - [ ] Hover: shadow-card-hover
  - [ ] Dialogs: shadow-dialog

---

### ✅ Performance

- [ ] **Build Size**
  - [ ] Run `npm run build`
  - [ ] Check `dist/` size (should be < 2MB)

- [ ] **Runtime Performance**
  - [ ] Open DevTools Performance tab
  - [ ] Record 10 seconds of interaction
  - [ ] Check FPS (should be >= 60fps)
  - [ ] Check memory usage (no leaks)

- [ ] **Network**
  - [ ] Camera polling: 2s interval
  - [ ] Discovery polling: 10s interval
  - [ ] Debounced settings: 300ms delay
  - [ ] No unnecessary API calls

---

### ✅ Error Handling

- [ ] **API Errors**
  - [ ] Failed to add camera: alert shown
  - [ ] Failed to start stream: alert shown
  - [ ] Failed to measure WB: alert shown
  - [ ] Network timeout: graceful fallback

- [ ] **Validation**
  - [ ] Empty IP address: form validation
  - [ ] Invalid port: form validation
  - [ ] Empty token: form validation
  - [ ] Empty profile name: alert shown

- [ ] **Edge Cases**
  - [ ] No cameras found: empty state message
  - [ ] Camera disconnected: "Disconnected" label
  - [ ] Zero cameras selected: "No cameras selected" alert

---

### ✅ Browser Compatibility

- [ ] **Chromium-based (Primary)**
  - [ ] Chrome 105+ (Tauri requirement)
  - [ ] Edge 105+

- [ ] **Webkit (macOS)**
  - [ ] Safari 13+ (Tauri requirement)

- [ ] **Test Features**
  - [ ] CSS Grid layout
  - [ ] CSS custom properties (--tw-*)
  - [ ] `<dialog>` element (via Melt UI polyfill)
  - [ ] Input type="range" styling

---

### ✅ Code Quality

- [ ] **TypeScript**
  - [ ] Run `npx tsc --noEmit`
  - [ ] Zero type errors

- [ ] **Linting**
  - [ ] No console.errors (except intentional logging)
  - [ ] No unused imports
  - [ ] No unused variables

- [ ] **Best Practices**
  - [ ] Sanitize user inputs (IP, token)
  - [ ] No `eval()` or `dangerouslySetInnerHTML`
  - [ ] Secure by default (Bearer token auth)

---

## Rollback Plan

If issues arise, restore the backup:

```bash
cd /home/user/avolo-cam/tauri-controller/src
mv App.svelte App.svelte.new
mv App.svelte.backup App.svelte
```

Then reinstall original dependencies:

```bash
npm uninstall tailwindcss postcss autoprefixer @melt-ui/svelte @melt-ui/pp typescript svelte-preprocess @tsconfig/svelte
```

---

## Post-Migration Cleanup

After successful testing:

```bash
# Remove backup
rm /home/user/avolo-cam/tauri-controller/src/App.svelte.backup

# Commit changes
cd /home/user/avolo-cam
git add .
git commit -m "refactor(ui): redesign with Tailwind + Melt UI, atomic components"
git push origin claude/redesign-ui-refactor-svelte-011CUudPULW4DBeELn2VfqJ9
```

---

## Quick Smoke Test

Run this sequence to verify critical paths:

1. Start dev server: `npm run tauri:dev`
2. Click "+ Add Camera" → Fill form → Submit
3. Click camera checkbox → Verify group controls appear
4. Click "⚙️" on a camera → Settings dialog opens
5. Adjust sliders → Verify debounced updates (300ms)
6. Click "📸 Auto Calibrate" → Verify WB measurement
7. Click "📋 Profiles" → Save profile → Apply to selected
8. Close app → Restart → Verify state persists (profiles)

If all steps pass: ✅ Migration successful!

---

## Support & Troubleshooting

### Common Issues

**1. TypeScript errors**
```bash
# Regenerate tsconfig
npx tsc --init
```

**2. Tailwind not applying styles**
```bash
# Verify postcss.config.js exists
# Check app.css has @tailwind directives
# Restart dev server
```

**3. Melt UI components not rendering**
```bash
# Check imports: import { createDialog } from '@melt-ui/svelte'
# Verify @melt-ui/svelte is installed
```

**4. Path alias not working**
```bash
# Check tsconfig.json has:
# "paths": { "$lib": ["./src/lib"], "$lib/*": ["./src/lib/*"] }
# Restart Vite dev server
```

---

## Next Steps

After successful migration:

1. **Add Unit Tests** (Vitest + Svelte Testing Library)
2. **Add E2E Tests** (Playwright)
3. **Document Components** (Storybook or inline docs)
4. **Accessibility Audit** (Lighthouse, axe-core)
5. **Performance Profiling** (Chrome DevTools)

---

**Migration completed successfully!** 🎉
