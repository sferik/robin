// Pausing a job class across every queue (Robin::JobClass): its jobs are
// set aside as workers fetch them, until it's resumed.
import { enc } from "./api";
import { act, post } from "./actions";
import { t } from "./i18n";

/** Pauses (after confirming) or resumes the job class `name`. */
export function pauseClass(cls: { name: string; paused: boolean }, reload: () => void) {
  return act(
    () => post(`classes/${enc(cls.name)}/${cls.paused ? "unpause" : "pause"}`),
    cls.paused ? t("Resumed {class}", { class: cls.name }) : t("Paused {class}", { class: cls.name }),
    cls.paused ? undefined : {
      title: t("Pause {class}?", { class: cls.name }),
      body: t("Workers set its jobs aside, in every queue, until you resume it. Jobs already running finish."),
      action: t("Pause class"),
    },
  ).then(reload);
}
