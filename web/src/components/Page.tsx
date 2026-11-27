import { ArrowLeftIcon, CaretLeftIcon, GearSixIcon } from "@phosphor-icons/react";
import type { ButtonHTMLAttributes, ReactNode } from "react";
import { useNavigate } from "react-router";
import { useT } from "../i18n";
import { cn } from "../lib/format";
import { needsAttention, useSystem } from "../stores/system";
import { useUi } from "../stores/ui";
import { LogoMark } from "./Brand";
import { IconButton } from "./IconButton";

/** Sticky page header. On phones it carries the brand mark and the settings entry, since there is no rail. */
export function PageHeader({
  title,
  actions,
  mobileOnly,
  className,
}: {
  title?: ReactNode;
  actions?: ReactNode;
  /** Pages with their own large hero title only need the compact bar on phones. */
  mobileOnly?: boolean;
  className?: string;
}) {
  const setSettingsOpen = useUi((s) => s.setSettingsOpen);
  const attention = useSystem((s) => needsAttention(s.info));
  const t = useT();
  return (
    <header
      className={cn(
        "safe-top sticky top-0 z-10 bg-bg/80 backdrop-blur-xl md:bg-surface-1/80",
        // Without a title or actions the header only exists for the phone brand bar.
        ((!title && !actions) || mobileOnly) && "md:hidden",
        className,
      )}
    >
      <div className="flex h-14 items-center gap-3 px-4 md:h-16 md:px-6">
        <LogoMark className="size-7 shrink-0 text-accent-text md:hidden" />
        {title && <h1 className="min-w-0 flex-1 truncate text-lg font-semibold tracking-tight md:text-xl">{title}</h1>}
        {!title && <span className="flex-1" />}
        {actions}
        <IconButton
          label={attention ? t.nav.settingsUpdate : t.nav.settings}
          onClick={() => setSettingsOpen(true)}
          className="-mr-2 md:hidden"
        >
          <GearSixIcon size={22} />
          {attention && <span className="absolute top-2 right-2 size-2 rounded-full bg-accent ring-2 ring-bg" />}
        </IconButton>
      </div>
    </header>
  );
}

export function Section({ title, action, children, className }: { title: string; action?: ReactNode; children: ReactNode; className?: string }) {
  return (
    <section className={cn("flex flex-col gap-3", className)}>
      <div className="flex items-end justify-between gap-4 px-4 md:px-6">
        <h2 className="text-xl font-semibold tracking-tight">{title}</h2>
        {action}
      </div>
      {children}
    </section>
  );
}

/** Back in history when there is somewhere to go back to (in the app), else to `fallback`. */
export function BackButton({ fallback, label }: { fallback: string; label?: string }) {
  const navigate = useNavigate();
  const t = useT();
  return (
    <button
      type="button"
      onClick={() => ((window.history.state as { idx?: number } | null)?.idx ? navigate(-1) : navigate(fallback))}
      className="flex h-9 shrink-0 items-center gap-1.5 rounded-full px-3 text-sm font-medium text-fg-2 hover:bg-surface-3 hover:text-fg"
    >
      <ArrowLeftIcon size={16} /> {label ?? t.common.back}
    </button>
  );
}

/** Frosted circular control for use over full-bleed artwork. */
export function GlassCircleButton({
  label,
  className,
  children,
  ...rest
}: ButtonHTMLAttributes<HTMLButtonElement> & { label: string }) {
  return (
    <button
      type="button"
      aria-label={label}
      title={label}
      {...rest}
      className={cn(
        "relative grid size-9 shrink-0 place-items-center rounded-full bg-black/35 text-white ring-1 ring-white/20 backdrop-blur-xl",
        "transition-[transform,background-color] duration-150 hover:bg-black/50 active:scale-90 focus-visible:outline-white",
        className,
      )}
    >
      {children}
    </button>
  );
}

/** Transparent navigation cluster that floats over a hero and clears the status bar. */
export function HeroHeader({ back, actions }: { back: ReactNode; actions: ReactNode }) {
  return (
    <header
      className={cn(
        "pointer-events-none absolute inset-x-0 top-0 z-20 flex items-start justify-between",
        "px-3 pt-[calc(env(safe-area-inset-top)+0.5rem)] md:px-4",
      )}
    >
      <div className="pointer-events-auto flex items-center">{back}</div>
      <div className="pointer-events-auto flex items-center gap-0.5 rounded-full bg-black/25 p-1 ring-1 ring-white/15 backdrop-blur-xl">
        {actions}
      </div>
    </header>
  );
}

/** Back in history when there is somewhere to go back to (in the app), else to `fallback`. */
export function HeroBackButton({ fallback }: { fallback: string }) {
  const navigate = useNavigate();
  const t = useT();
  return (
    <GlassCircleButton
      label={t.common.back}
      onClick={() => ((window.history.state as { idx?: number } | null)?.idx ? navigate(-1) : navigate(fallback))}
    >
      <CaretLeftIcon size={20} weight="bold" />
    </GlassCircleButton>
  );
}

export function EmptyState({ icon, title, body, action }: { icon: ReactNode; title: string; body: string; action?: ReactNode }) {
  return (
    <div className="flex flex-col items-center gap-3 px-6 py-16 text-center">
      <span className="grid size-16 place-items-center rounded-[18px] bg-surface-3 text-fg-2">{icon}</span>
      <p className="text-lg font-semibold tracking-tight">{title}</p>
      <p className="max-w-[40ch] text-sm text-fg-2">{body}</p>
      {action}
    </div>
  );
}
