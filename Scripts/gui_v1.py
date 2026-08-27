import tkinter as tk
from tkinter import ttk, messagebox
import subprocess
import pathlib
from datetime import datetime, date, time

from tkcalendar import DateEntry  # pip install tkcalendar


# --- CONFIGURATION -------------------------------------------------

import json

CONFIG_PATH = pathlib.Path(r"C:\Users\5CG7471GSJ\Documents\DATA\Scripts\GUI\config.json")

with CONFIG_PATH.open("r", encoding="utf-8") as f:
    CONFIG = json.load(f)



DATA_DIR = pathlib.Path(r"C:\Users\5CG7471GSJ\Documents\DATA")
DATA_DIR.mkdir(parents=True, exist_ok=True)

SCRIPTS_DIR = pathlib.Path(CONFIG["paths"]["scripts_dir"])

UPLOAD_GITHUB_SCRIPT = SCRIPTS_DIR / "upload_to_repo.ps1"


SHELLY_LOGGER_SCRIPT = SCRIPTS_DIR / CONFIG["paths"]["shelly_logger"]
TAROM_LOGGER_SCRIPT = SCRIPTS_DIR / CONFIG["paths"]["tarom_logger"]
SHELLY_SCENARIO_SCRIPT = SCRIPTS_DIR / CONFIG["paths"]["shelly_scenario"]
UPLOAD_GITHUB_SCRIPT = SCRIPTS_DIR / CONFIG["paths"]["upload_github"]


# Single load selector (used for file naming + scenario script)
SCENARIOS = ["all_on", "whole_house", "constant_1kw", "adaptive"]

SHELLY_LOG_DIR = pathlib.Path(CONFIG["log_dirs"]["shelly"])
TAROM_LOG_DIR = pathlib.Path(CONFIG["log_dirs"]["tarom"])

SHELLY_LOG_DIR.mkdir(parents=True, exist_ok=True)
TAROM_LOG_DIR.mkdir(parents=True, exist_ok=True)


class PVControlApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("PV Data Collection Control")
        self.geometry("780x360")

        # Process handles
        self.shelly_proc = None
        self.tarom_proc = None
        self.github_proc = None
        self.scenario_proc = None

        # Running-status vars (for checkboxes)
        self.shelly_running_var = tk.BooleanVar(value=False)
        self.tarom_running_var = tk.BooleanVar(value=False)
        self.github_running_var = tk.BooleanVar(value=False)
        self.scenario_running_var = tk.BooleanVar(value=False)

        # Scheduling vars
        self.use_start_var = tk.BooleanVar(value=False)
        self.use_stop_var = tk.BooleanVar(value=False)
        self.start_timer_id = None
        self.stop_timer_id = None

        self.create_widgets()
        self.update_name_preview()

    def create_widgets(self):
        # Layout: two main columns with equal width
        self.grid_columnconfigure(0, weight=1, uniform="col")
        self.grid_columnconfigure(1, weight=1, uniform="col")

        # Tilt selector
        tk.Label(self, text="Tilt (deg):").grid(
            row=0, column=0, sticky="w", padx=10, pady=5
        )
        self.tilt_var = tk.IntVar(value=30)
        tilt_spin = tk.Spinbox(
            self,
            from_=0,
            to=90,
            textvariable=self.tilt_var,
            width=5,
            command=self.update_name_preview,
        )
        tilt_spin.grid(row=0, column=1, padx=10, pady=5, sticky="w")

        # Distance selector
        tk.Label(self, text="Distance (mm):").grid(
            row=1, column=0, sticky="w", padx=10, pady=5
        )
        self.distance_var = tk.IntVar(value=50)
        distance_spin = tk.Spinbox(
            self,
            from_=0,
            to=1000,
            increment=10,
            textvariable=self.distance_var,
            width=5,
            command=self.update_name_preview,
        )
        distance_spin.grid(row=1, column=1, padx=10, pady=5, sticky="w")

        # Single load selector (scenario/profile)
        tk.Label(self, text="Load scenario / profile:").grid(
            row=2, column=0, sticky="w", padx=10, pady=5
        )
        self.scenario_var = tk.StringVar(value=SCENARIOS[0])
        scenario_combo = ttk.Combobox(
            self,
            textvariable=self.scenario_var,
            values=SCENARIOS,
            state="readonly",
        )
        scenario_combo.grid(row=2, column=1, padx=10, pady=5, sticky="we")
        self.scenario_var.trace_add("write", lambda *args: self.update_name_preview())

        # Name preview
        tk.Label(self, text="File name preview:").grid(
            row=3, column=0, sticky="w", padx=10, pady=5
        )
        self.preview_var = tk.StringVar()
        tk.Label(self, textvariable=self.preview_var, anchor="w").grid(
            row=3, column=1, sticky="we", padx=10, pady=5
        )

        # --- Scheduling controls with calendar-style date selection (aligned) ---

        # Define these once (if not already done earlier)
        self.use_start_var = tk.BooleanVar(value=False)
        self.use_stop_var  = tk.BooleanVar(value=False)

        schedule_frame = tk.Frame(self)
        schedule_frame.grid(row=4, column=0, columnspan=2, sticky="w", padx=10, pady=4)

        # Same column layout for both rows
        for c in range(6):
            schedule_frame.grid_columnconfigure(c, weight=0)

        # START row (row = 0)
        start_check = tk.Checkbutton(
            schedule_frame,
            text="Schedule START:",
            variable=self.use_start_var,
        )
        start_check.grid(row=0, column=0, sticky="w")

        self.start_date = DateEntry(
            schedule_frame,
            width=12,
            date_pattern="yyyy-mm-dd",
        )
        self.start_date.grid(row=0, column=1, sticky="w", padx=5)

        tk.Label(schedule_frame, text="Time:").grid(row=0, column=2, sticky="w", padx=5)

        self.start_hour_var = tk.StringVar(value="08")
        self.start_min_var  = tk.StringVar(value="00")

        start_hour_spin = tk.Spinbox(
            schedule_frame,
            from_=0,
            to=23,
            width=2,
            textvariable=self.start_hour_var,
            format="%02.0f",
        )
        start_min_spin = tk.Spinbox(
            schedule_frame,
            from_=0,
            to=59,
            width=2,
            textvariable=self.start_min_var,
            format="%02.0f",
        )

        start_hour_spin.grid(row=0, column=3, sticky="w")
        tk.Label(schedule_frame, text=":").grid(row=0, column=4, sticky="w")
        start_min_spin.grid(row=0, column=5, sticky="w")

        # STOP row (row = 1)
        stop_check = tk.Checkbutton(
            schedule_frame,
            text="Schedule STOP:",
            variable=self.use_stop_var,
        )
        stop_check.grid(row=1, column=0, sticky="w", pady=(2, 0))

        self.stop_date = DateEntry(
            schedule_frame,
            width=12,
            date_pattern="yyyy-mm-dd",
        )
        self.stop_date.grid(row=1, column=1, sticky="w", padx=5)

        tk.Label(schedule_frame, text="Time:").grid(row=1, column=2, sticky="w", padx=5)

        self.stop_hour_var = tk.StringVar(value="20")
        self.stop_min_var  = tk.StringVar(value="00")

        stop_hour_spin = tk.Spinbox(
            schedule_frame,
            from_=0,
            to=23,
            width=2,
            textvariable=self.stop_hour_var,
            format="%02.0f",
        )
        stop_min_spin = tk.Spinbox(
            schedule_frame,
            from_=0,
            to=59,
            width=2,
            textvariable=self.stop_min_var,
            format="%02.0f",
        )

        stop_hour_spin.grid(row=1, column=3, sticky="w")
        tk.Label(schedule_frame, text=":").grid(row=1, column=4, sticky="w")
        stop_min_spin.grid(row=1, column=5, sticky="w")

        # --- Start / Stop row ---

        start_all_btn = tk.Button(
            self,
            text="Start ALL",
            command=self.start_all,
            bg="green",
            fg="white",
            activebackground="darkgreen",
            activeforeground="white",
        )
        start_all_btn.grid(row=6, column=0, padx=10, pady=8, sticky="we")

        stop_btn = tk.Button(
            self,
            text="Stop ALL",
            command=self.stop_loggers,
            bg="red",
            fg="white",
            activebackground="darkred",
            activeforeground="white",
        )
        stop_btn.grid(row=6, column=1, padx=10, pady=8, sticky="we")

        # --- Row for individual script buttons + status checkboxes ---

        buttons_frame = tk.Frame(self)
        buttons_frame.grid(
            row=7, column=0, columnspan=2, padx=10, pady=5, sticky="we"
        )

        for i in range(4):
            buttons_frame.grid_columnconfigure(i, weight=1, uniform="btns")

        shelly_btn = tk.Button(
            buttons_frame,
            text="Shelly logger",
            command=self.start_shelly_logger,
        )
        shelly_btn.grid(row=0, column=0, padx=3, pady=3, sticky="we")

        tarom_btn = tk.Button(
            buttons_frame,
            text="Tarom logger",
            command=self.start_tarom_logger,
        )
        tarom_btn.grid(row=0, column=1, padx=3, pady=3, sticky="we")

        upload_btn = tk.Button(
            buttons_frame,
            text="Upload GitHub",
            command=self.upload_github,
        )
        upload_btn.grid(row=0, column=2, padx=3, pady=3, sticky="we")

        scenario_script_btn = tk.Button(
            buttons_frame,
            text="Scenario script",
            command=self.apply_scenario_script,
        )
        scenario_script_btn.grid(row=0, column=3, padx=3, pady=3, sticky="we")

        # Running-status checkboxes (read-only indicators)
        tk.Checkbutton(
            buttons_frame,
            text="Shelly running",
            variable=self.shelly_running_var,
            onvalue=True,
            offvalue=False,
            state="disabled",
        ).grid(row=1, column=0, padx=3, pady=2, sticky="w")

        tk.Checkbutton(
            buttons_frame,
            text="Tarom running",
            variable=self.tarom_running_var,
            onvalue=True,
            offvalue=False,
            state="disabled",
        ).grid(row=1, column=1, padx=3, pady=2, sticky="w")

        tk.Checkbutton(
            buttons_frame,
            text="GitHub running",
            variable=self.github_running_var,
            onvalue=True,
            offvalue=False,
            state="disabled",
        ).grid(row=1, column=2, padx=3, pady=2, sticky="w")

        tk.Checkbutton(
            buttons_frame,
            text="Scenario running",
            variable=self.scenario_running_var,
            onvalue=True,
            offvalue=False,
            state="disabled",
        ).grid(row=1, column=3, padx=3, pady=2, sticky="w")

        # Status label
        self.status_var = tk.StringVar(value="Ready.")
        tk.Label(self, textvariable=self.status_var, anchor="w").grid(
            row=8, column=0, columnspan=2, sticky="we", padx=10, pady=5
        )

    # --- Naming logic ------------------------------------------------

    def build_measurement_names(self):
        """
        Returns (shelly_path, tarom_path) based on tilt, distance and scenario.

        Pattern:
          Shelly (load): load_tiltNN_distanceMM_<scenario>.txt
          Tarom  (pv)  :  pv_tiltNN_distanceMM_<scenario>.txt
        """
        tilt = self.tilt_var.get()
        distance = self.distance_var.get()
        scenario = self.scenario_var.get().strip()

        if not scenario:
            raise ValueError("Please select a load scenario.")

        base = f"tilt{tilt}_distance{distance}_{scenario}"
        shelly_name = f"load_{base}.txt"
        tarom_name = f"pv_{base}.txt"

        shelly_path = SHELLY_LOG_DIR / shelly_name
        tarom_path = TAROM_LOG_DIR / tarom_name

        return shelly_path, tarom_path

    def update_name_preview(self, *args):
        try:
            shelly_path, tarom_path = self.build_measurement_names()
            self.preview_var.set(
                f"Shelly: {shelly_path.name}   |   Tarom: {tarom_path.name}"
            )
        except Exception:
            self.preview_var.set("")

    # --- Scheduling helpers -----------------------------------------

    def get_start_datetime(self) -> datetime:
        d: date = self.start_date.get_date()
        h = int(self.start_hour_var.get() or 0)
        m = int(self.start_min_var.get() or 0)
        return datetime.combine(d, time(hour=h, minute=m))

    def get_stop_datetime(self) -> datetime:
        d: date = self.stop_date.get_date()
        h = int(self.stop_hour_var.get() or 0)
        m = int(self.stop_min_var.get() or 0)
        return datetime.combine(d, time(hour=h, minute=m))

    def schedule_start_datetime(self, dt: datetime):
        if self.start_timer_id is not None:
            self.after_cancel(self.start_timer_id)
            self.start_timer_id = None

        now = datetime.now()
        delta_ms = (dt - now).total_seconds() * 1000

        if delta_ms <= 0:
            self._start_all_now()
            return

        self.status_var.set(f"Start scheduled at {dt.strftime('%Y-%m-%d %H:%M')}.")
        self.start_timer_id = self.after(int(delta_ms), self._start_all_now)

    def schedule_stop_datetime(self, dt: datetime):
        if self.stop_timer_id is not None:
            self.after_cancel(self.stop_timer_id)
            self.stop_timer_id = None

        now = datetime.now()
        delta_ms = (dt - now).total_seconds() * 1000

        if delta_ms <= 0:
            # Past stop time: ignore; manual stop only
            return

        self.status_var.set(f"Stop scheduled at {dt.strftime('%Y-%m-%d %H:%M')}.")
        self.stop_timer_id = self.after(int(delta_ms), self.stop_loggers)

    # --- Start / Stop orchestration ---------------------------------

    def start_all(self):
        """
        Handle Start ALL with optional full date-time scheduling.

        - If start schedule enabled: schedule _start_all_now at given date+time.
        - Else: start immediately.
        - If stop schedule enabled: schedule stop_loggers at given date+time.
        """
        # Start scheduling
        if self.use_start_var.get():
            try:
                dt_start = self.get_start_datetime()
            except ValueError as e:
                messagebox.showerror("Start time error", str(e))
                return
            self.schedule_start_datetime(dt_start)
        else:
            self._start_all_now()

        # Stop scheduling
        if self.use_stop_var.get():
            try:
                dt_stop = self.get_stop_datetime()
            except ValueError as e:
                messagebox.showerror("Stop time error", str(e))
                return
            self.schedule_stop_datetime(dt_stop)

    def _start_all_now(self):
        try:
            self.start_shelly_logger()
            self.start_tarom_logger()
            self.upload_github()
            self.status_var.set("All scripts started (Shelly, Tarom, GitHub).")
        except Exception as e:
            messagebox.showerror("Start ALL error", str(e))

    def stop_loggers(self):
        """
        Stop Shelly and Tarom logger PowerShell processes if they are running.
        Also resets running-status checkboxes.
        """
        if self.stop_timer_id is not None:
            self.after_cancel(self.stop_timer_id)
            self.stop_timer_id = None

        stopped_any = False

        for name, attr, var in [
            ("Shelly", "shelly_proc", self.shelly_running_var),
            ("Tarom", "tarom_proc", self.tarom_running_var),
        ]:
            proc = getattr(self, attr, None)
            if proc is not None and proc.poll() is None:
                try:
                    proc.terminate()
                    stopped_any = True
                except Exception:
                    pass
                setattr(self, attr, None)
                var.set(False)

        if stopped_any:
            self.status_var.set("Loggers stopped.")
        else:
            self.status_var.set("No loggers were running.")

    # --- Individual PS1 actions -------------------------------------

    def start_shelly_logger(self):
        shelly_path, _ = self.build_measurement_names()

        self.status_var.set(f"Starting Shelly logger -> {shelly_path} ...")

        self.shelly_proc = subprocess.Popen(
            [
                "powershell",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(SHELLY_LOGGER_SCRIPT),
                "-OutFile",
                str(shelly_path),
            ]
        )
        self.shelly_running_var.set(True)

    def start_tarom_logger(self):
        _, tarom_path = self.build_measurement_names()

        self.status_var.set(f"Starting Tarom logger -> {tarom_path} ...")

        self.tarom_proc = subprocess.Popen(
            [
                "powershell",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(TAROM_LOGGER_SCRIPT),
                "-OutFile",
                str(tarom_path),
            ]
        )
        self.tarom_running_var.set(True)

    def upload_github(self):
        self.status_var.set("Uploading to GitHub (background)...")

        self.github_proc = subprocess.Popen(
            [
                "powershell",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(UPLOAD_GITHUB_SCRIPT),
            ]
        )
        self.github_running_var.set(True)
        self.after(500, self.check_github_process)

    def check_github_process(self):
        if self.github_proc is not None:
            if self.github_proc.poll() is None:
                self.after(500, self.check_github_process)
            else:
                self.github_running_var.set(False)
                self.github_proc = None

    def apply_scenario_script(self):
        """
        Call shelly_load_control_scenarios.ps1 -SetScenario -Scenario <value>.
        Uses current scenario selection, matching the file naming.
        """
        scenario = self.scenario_var.get()

        self.status_var.set(
            f"Requesting scenario '{scenario}' via Shelly control script..."
        )

        self.scenario_proc = subprocess.Popen(
            [
                "powershell",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(SHELLY_SCENARIO_SCRIPT),
                "-SetScenario",
                "-Scenario",
                scenario,
                "-RunOnce",
            ]
        )
        self.scenario_running_var.set(True)
        self.after(500, self.check_scenario_process)

    def check_scenario_process(self):
        if self.scenario_proc is not None:
            if self.scenario_proc.poll() is None:
                self.after(500, self.check_scenario_process)
            else:
                self.scenario_running_var.set(False)
                self.scenario_proc = None
                self.status_var.set("Scenario script finished.")


if __name__ == "__main__":
    app = PVControlApp()
    app.mainloop()