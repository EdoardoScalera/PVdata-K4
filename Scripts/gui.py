import tkinter as tk
from tkinter import ttk, messagebox
import subprocess
import pathlib
import webbrowser
from datetime import datetime, date, time, timedelta

from tkcalendar import DateEntry  # pip install tkcalendar

# --- CONFIGURATION -------------------------------------------------

import json

CONFIG_PATH = pathlib.Path(__file__).resolve().parent / "config.json"
REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent

with CONFIG_PATH.open("r", encoding="utf-8") as f:
    CONFIG = json.load(f)

DATA_DIR = pathlib.Path(CONFIG["data_dir"])
DATA_DIR.mkdir(parents=True, exist_ok=True)

SCRIPTS_DIR = pathlib.Path(CONFIG["paths"]["scripts_dir"])

SHELLY_LOGGER_SCRIPT = SCRIPTS_DIR / CONFIG["paths"]["shelly_logger"]
TAROM_LOGGER_SCRIPT = SCRIPTS_DIR / CONFIG["paths"]["tarom_logger"]
SHELLY_SCENARIO_SCRIPT = SCRIPTS_DIR / CONFIG["paths"]["shelly_scenario"]
SHELLY_SCENARIO_CONFIG = SCRIPTS_DIR / CONFIG["paths"]["shelly_scenario_config"]
UPLOAD_GITHUB_SCRIPT = SCRIPTS_DIR / CONFIG["paths"]["upload_github"]
LABVIEW_LOGGER_SCRIPT = SCRIPTS_DIR / CONFIG["paths"]["labview_logger"]
LABVIEW_PATH = pathlib.Path(CONFIG["labview"]["labview_path"])
LABVIEW_VI_PATH = pathlib.Path(CONFIG["labview"]["vi_path"])
SCENARIO_REQUEST_PATH = SCRIPTS_DIR / CONFIG["paths"]["scenario_request"]
SCENARIO_STATUS_PATH = SCRIPTS_DIR / CONFIG["paths"]["scenario_status"]
DASHBOARD_URL = CONFIG["dashboard_url"]
GITHUB_REPO_URL = "https://github.com/EdoardoScalera/PVdata-K4"
DASHBOARD_VALUES_FILE = pathlib.Path(CONFIG["dashboard_values_file"])

# Single load selector (used for file naming + scenario script)
SCENARIOS = ["all_on", "whole_house", "constant", "adaptive"]

# Display names for the scenario dropdowns. Internal values keep the file
# naming / script flags unchanged (e.g. "constant" -> "Constant load").
SCENARIO_LABELS = {
    "all_on": "All on",
    "whole_house": "Whole house",
    "constant": "Constant load",
    "adaptive": "Adaptive",
    "all_off": "All off",
}

SHELLY_LOG_DIR = pathlib.Path(CONFIG["log_dirs"]["shelly"])
TAROM_LOG_DIR = pathlib.Path(CONFIG["log_dirs"]["tarom"])
IRRADIANCE_LOG_DIR = pathlib.Path(CONFIG["log_dirs"]["irradiance"])

SHELLY_LOG_DIR.mkdir(parents=True, exist_ok=True)
TAROM_LOG_DIR.mkdir(parents=True, exist_ok=True)
IRRADIANCE_LOG_DIR.mkdir(parents=True, exist_ok=True)


class PVControlApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("PV Data Collection Control")
        self.geometry("1020x1000")
        self.minsize(960, 940)

        # Process handles
        self.shelly_proc = None
        self.tarom_proc = None
        self.github_proc = None
        self.scenario_proc = None
        self.all_off_proc = None
        self.scenario_request_procs = []
        self.labview_proc = None
        self.labview_running_var = tk.BooleanVar(value=False)

        # Running-status vars (for checkboxes)
        self.shelly_running_var = tk.BooleanVar(value=False)
        self.tarom_running_var = tk.BooleanVar(value=False)
        self.github_running_var = tk.BooleanVar(value=False)
        self.scenario_running_var = tk.BooleanVar(value=False)
        self.load_running_var = tk.BooleanVar(value=False)

        # Scheduling vars
        self.use_start_var = tk.BooleanVar(value=False)
        self.use_stop_var = tk.BooleanVar(value=False)
        self.start_timer_id = None
        self.stop_timer_id = None
        self.logger_restart_timer_id = None
        self.all_off_check_id = None

        self.viewer_refresh_id = None
        self.viewer_vars = {
            "controller": tk.StringVar(value="Unavailable"),
            "active": tk.StringVar(value="Unavailable"),
            "pending": tk.StringVar(value="None"),
            "requested_for": tk.StringVar(value="Unavailable"),
            "slot": tk.StringVar(value="Unavailable"),
            "target": tk.StringVar(value="Unavailable"),
            "last_push": tk.StringVar(value="Unavailable"),
            "load_w": tk.StringVar(value="Unavailable"),
            "pv1_w": tk.StringVar(value="Unavailable"),
            "pv2_w": tk.StringVar(value="Unavailable"),
            "pv_total_w": tk.StringVar(value="Unavailable"),
            "poa_front": tk.StringVar(value="Unavailable"),
            "poa_rear": tk.StringVar(value="Unavailable"),
            "tc1": tk.StringVar(value="Unavailable"),
            "tc2": tk.StringVar(value="Unavailable"),
            "tc3": tk.StringVar(value="Unavailable"),
            "tc4": tk.StringVar(value="Unavailable"),
        }
        self.applied_tilt = int(CONFIG.get("defaults", {}).get("tilt_deg", 30))
        self.applied_distance = int(CONFIG.get("defaults", {}).get("distance_cm", 50))
        self.applied_scenario = CONFIG.get("defaults", {}).get("scenario", "all_on")
        self.applied_constant_target = 1200

        self.create_widgets()
        self.update_name_preview()
        self.refresh_scenario_viewer()
        self.protocol("WM_DELETE_WINDOW", self.on_close)

    def create_widgets(self):
        # Layout: two main columns with equal width
        self.grid_columnconfigure(0, weight=1, uniform="col")
        self.grid_columnconfigure(1, weight=1, uniform="col")

        self.measurement_frame = tk.LabelFrame(self, text="Measurement")
        measurement_frame = self.measurement_frame
        measurement_frame.grid(row=0, column=0, padx=(10, 5), pady=(6, 2), sticky="nsew")
        measurement_frame.grid_columnconfigure(1, weight=1)

        tk.Label(measurement_frame, text="Tilt (deg):").grid(
            row=0, column=0, sticky="w", padx=10, pady=5
        )
        self.tilt_var = tk.IntVar(value=30)
        tilt_spin = tk.Spinbox(
            measurement_frame,
            from_=0,
            to=90,
            textvariable=self.tilt_var,
            width=5,
            command=self.update_name_preview,
        )
        tilt_spin.grid(row=0, column=1, padx=10, pady=5, sticky="w")
        self.tilt_var.trace_add("write", self.on_measurement_parameter_changed)

        tk.Label(measurement_frame, text="Distance (cm):").grid(
            row=1, column=0, sticky="w", padx=10, pady=5
        )
        self.distance_var = tk.IntVar(value=50)
        distance_spin = tk.Spinbox(
            measurement_frame,
            from_=0,
            to=1000,
            increment=10,
            textvariable=self.distance_var,
            width=5,
            command=self.update_name_preview,
        )
        distance_spin.grid(row=1, column=1, padx=10, pady=5, sticky="w")
        self.distance_var.trace_add("write", self.on_measurement_parameter_changed)

        # Single load selector (scenario/profile)
        tk.Label(measurement_frame, text="Load scenario / profile:").grid(
            row=2, column=0, sticky="w", padx=10, pady=5
        )
        self.scenario_var = tk.StringVar(value=SCENARIO_LABELS[SCENARIOS[0]])
        scenario_combo = ttk.Combobox(
            measurement_frame,
            textvariable=self.scenario_var,
            values=[SCENARIO_LABELS[s] for s in SCENARIOS],
            state="readonly",
        )
        scenario_combo.configure(width=20)
        scenario_combo.grid(row=2, column=1, padx=10, pady=5, sticky="w")
        self.scenario_var.trace_add("write", self.update_name_preview_and_target_state)
        scenario_combo.bind("<<ComboboxSelected>>", self.on_scenario_selected)

        tk.Label(measurement_frame, text="Constant load (W):").grid(
            row=3, column=0, sticky="w", padx=10, pady=5
        )
        self.constant_target_var = tk.StringVar(value="1200")
        constant_target_entry = tk.Entry(
            measurement_frame,
            textvariable=self.constant_target_var,
            width=8,
            validate="key",
            validatecommand=(self.register(self.validate_constant_target), "%P"),
        )
        self.constant_target_entry = constant_target_entry
        constant_target_entry.grid(row=3, column=1, padx=10, pady=5, sticky="w")
        self.constant_target_var.trace_add("write", self.on_constant_target_changed)

        tk.Label(measurement_frame, text="File name preview:").grid(
            row=4, column=0, sticky="w", padx=10, pady=5
        )
        self.preview_var = tk.StringVar()
        tk.Label(measurement_frame, textvariable=self.preview_var, anchor="w").grid(
            row=4, column=1, sticky="we", padx=10, pady=5
        )
        tk.Button(
            measurement_frame,
            text="Set measurement",
            command=self.set_measurement_parameters,
        ).grid(row=5, column=0, columnspan=2, padx=10, pady=5, sticky="we")

        utilities_frame = tk.LabelFrame(self, text="Utilities")
        utilities_frame.grid(row=0, column=1, padx=(5, 10), pady=(6, 2), sticky="nsew")
        utilities_frame.grid_columnconfigure(0, weight=1)
        tk.Button(
            utilities_frame,
            text="Open Data directory",
            command=self.open_data_directory,
        ).grid(row=0, column=0, padx=8, pady=8, sticky="we")
        tk.Button(
            utilities_frame,
            text="Open live dashboard",
            command=self.open_live_dashboard,
        ).grid(row=1, column=0, padx=8, pady=(0, 8), sticky="we")
        tk.Button(
            utilities_frame,
            text="Open GitHub repo",
            command=self.open_github_repo,
        ).grid(row=2, column=0, padx=8, pady=(0, 8), sticky="we")

        # --- Scheduling controls with calendar-style date selection (aligned) ---

        schedule_frame = tk.LabelFrame(self, text="Scheduling")
        schedule_frame.grid(row=1, column=0, columnspan=2, sticky="we", padx=10, pady=4)

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

        tk.Label(schedule_frame, text="Time:").grid(
            row=0, column=2, sticky="w", padx=5
        )

        self.start_hour_var = tk.StringVar(value="08")
        self.start_min_var = tk.StringVar(value="00")

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

        tk.Label(schedule_frame, text="Time:").grid(
            row=1, column=2, sticky="w", padx=5
        )

        self.stop_hour_var = tk.StringVar(value="20")
        self.stop_min_var = tk.StringVar(value="00")

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

        self.start_all_btn = tk.Button(
            self,
            text="Start ALL",
            command=self.start_all,
            bg="green",
            fg="white",
            activebackground="darkgreen",
            activeforeground="white",
        )
        self.start_all_btn.grid(row=2, column=0, padx=10, pady=8, sticky="we")

        stop_btn = tk.Button(
            self,
            text="Stop ALL",
            command=self.stop_loggers,
            bg="red",
            fg="white",
            activebackground="darkred",
            activeforeground="white",
        )
        stop_btn.grid(row=2, column=1, padx=10, pady=8, sticky="we")

        actions_frame = tk.Frame(self)
        actions_frame.grid(row=3, column=0, columnspan=2, padx=10, pady=5, sticky="nsew")
        actions_frame.grid_columnconfigure(0, weight=1)

        # Logging section: spans the full width of the window.
        # Each row is Start | state checkbox | Stop; stop buttons are narrower.
        logging_frame = tk.LabelFrame(actions_frame, text="Logging")
        logging_frame.grid(row=0, column=0, sticky="nsew")
        logging_frame.grid_columnconfigure(0, weight=2)
        logging_frame.grid_columnconfigure(1, weight=0)
        logging_frame.grid_columnconfigure(2, weight=1)

        # Combined Load + controller row: the controller boots up (applying the
        # desired load) and the Load logger records it in one action. A single
        # checkbox reflects the state of both.
        self.start_shelly_ctrl_btn = tk.Button(logging_frame, text="Start Load + controller", command=self.start_shelly_controller)
        self.start_shelly_ctrl_btn.grid(row=0, column=0, padx=3, pady=3, sticky="we")
        tk.Checkbutton(logging_frame, text="Load + controller", variable=self.load_running_var, state="disabled").grid(row=0, column=1, sticky="w", padx=3)
        tk.Button(logging_frame, text="Stop Load + controller", command=self.stop_shelly_controller).grid(row=0, column=2, padx=3, pady=3, sticky="we")

        self.start_tarom_btn = tk.Button(logging_frame, text="Start MPPT", command=self.start_tarom_logger)
        self.start_tarom_btn.grid(row=1, column=0, padx=3, pady=3, sticky="we")
        tk.Checkbutton(logging_frame, text="MPPT", variable=self.tarom_running_var, state="disabled").grid(row=1, column=1, sticky="w", padx=3)
        tk.Button(logging_frame, text="Stop MPPT", command=self.stop_tarom_logger).grid(row=1, column=2, padx=3, pady=3, sticky="we")

        self.start_labview_btn = tk.Button(logging_frame, text="Start LabVIEW VI", command=self.start_labview_logger)
        self.start_labview_btn.grid(row=2, column=0, padx=3, pady=3, sticky="we")
        tk.Checkbutton(logging_frame, text="LabVIEW", variable=self.labview_running_var, state="disabled").grid(row=2, column=1, sticky="w", padx=3)
        tk.Button(logging_frame, text="Stop LabVIEW VI", command=self.stop_labview_logger).grid(row=2, column=2, padx=3, pady=3, sticky="we")

        # GitHub is kept as the last entry in the logging section
        self.start_github_btn = tk.Button(logging_frame, text="Upload GitHub", command=self.upload_github)
        self.start_github_btn.grid(row=3, column=0, padx=3, pady=3, sticky="we")
        tk.Checkbutton(logging_frame, text="GitHub", variable=self.github_running_var, state="disabled").grid(row=3, column=1, sticky="w", padx=3)
        tk.Button(logging_frame, text="Stop GitHub", command=self.stop_github_upload).grid(row=3, column=2, padx=3, pady=3, sticky="we")

        # Scenario control: full width, placed below the logging section.
        # A profile dropdown + request button (mimics the measurement section),
        # with the immediate all-off button kept as-is.
        scenario_frame = tk.LabelFrame(actions_frame, text="Scenario control")
        scenario_frame.grid(row=1, column=0, pady=(8, 0), sticky="we")
        scenario_frame.grid_columnconfigure(1, weight=1)

        tk.Label(scenario_frame, text="Scenario profile:").grid(row=0, column=0, sticky="w", padx=(8, 3), pady=3)
        self.scenario_control_var = tk.StringVar(value=SCENARIO_LABELS[SCENARIOS[0]])
        scenario_control_combo = ttk.Combobox(
            scenario_frame,
            textvariable=self.scenario_control_var,
            values=[SCENARIO_LABELS[s] for s in SCENARIOS + ["all_off"]],
            state="readonly",
            width=12,
        )
        scenario_control_combo.grid(row=0, column=1, padx=3, pady=3, sticky="w")
        self.scenario_control_var.trace_add("write", self.update_scenario_constant_target_state)
        tk.Button(
            scenario_frame,
            text="Request scenario",
            command=self.request_scenario_from_control,
        ).grid(row=0, column=2, padx=3, pady=3, sticky="we")
        tk.Button(
            scenario_frame,
            text="Turn OFF NOW",
            command=self.scenario_all_off_now,
            bg="orange",
            fg="white",
        ).grid(row=0, column=3, padx=(28, 8), pady=3, sticky="we")

        # Constant load entry for the constant scenario (shared with the measurement section)
        tk.Label(scenario_frame, text="Constant load (W):").grid(row=1, column=0, sticky="e", padx=(3, 0), pady=3)
        self.scenario_constant_entry = tk.Entry(
            scenario_frame,
            textvariable=self.constant_target_var,
            width=8,
            validate="key",
            validatecommand=(self.register(self.validate_constant_target), "%P"),
        )
        self.scenario_constant_entry.grid(row=1, column=1, columnspan=3, sticky="w", padx=3, pady=3)

        self.update_start_button_states()

        viewer_frame = tk.LabelFrame(self, text="Logger state", padx=8, pady=4)
        viewer_frame.grid(row=4, column=0, columnspan=2, padx=10, pady=4, sticky="we")
        viewer_frame.grid_columnconfigure(1, weight=1)
        viewer_frame.grid_columnconfigure(3, weight=1)
        viewer_rows = [
            ("Controller", "controller"),
            ("Current scenario", "active"),
            ("Pending scenario", "pending"),
            ("Requested for", "requested_for"),
            ("Current slot", "slot"),
            ("Current target", "target"),
            ("Last GitHub push", "last_push"),
            ("Load", "load_w"),
            ("PV1 (MPPT)", "pv1_w"),
            ("PV2 (MPPT)", "pv2_w"),
            ("PV total", "pv_total_w"),
            ("POA front", "poa_front"),
            ("POA rear", "poa_rear"),
            ("TC1", "tc1"),
            ("TC2", "tc2"),
            ("TC3", "tc3"),
            ("TC4", "tc4"),
        ]
        # Split the entries into two columns: labels in column 0 and 2, values
        # in column 1 and 3. Both halves share the same number of rows.
        half = (len(viewer_rows) + 1) // 2
        for idx, (label, key) in enumerate(viewer_rows):
            col = 0 if idx < half else 2
            r = idx if idx < half else idx - half
            tk.Label(viewer_frame, text=f"{label}:", anchor="w").grid(
                row=r, column=col, sticky="w", padx=(0, 10)
            )
            tk.Label(viewer_frame, textvariable=self.viewer_vars[key], anchor="w").grid(
                row=r, column=col + 1, sticky="we"
            )

        # Status label
        self.status_var = tk.StringVar(value="Ready.")
        self.status_label = tk.Label(
            self,
            textvariable=self.status_var,
            anchor="w",
            justify="left",
            wraplength=940,
        )
        self.status_label.grid(
            row=5, column=0, columnspan=2, sticky="we", padx=10, pady=5
        )
        self.update_constant_target_state()
        self.update_scenario_constant_target_state()

    # --- Naming logic ------------------------------------------------

    def _scenario_label(self, value):
        """Display label for an internal scenario value."""
        return SCENARIO_LABELS.get(value, value)

    def _scenario_value(self, label):
        """Internal scenario value for a display label."""
        for key, text in SCENARIO_LABELS.items():
            if text == label:
                return key
        return label

    def _build_base_name(self):
        """
        Returns the common file-name base, e.g. "tilt30_distance50_all_on".
        """
        scenario = self.applied_scenario.strip()
        if not scenario:
            raise ValueError("Please select a load scenario.")
        scenario_suffix = scenario
        if scenario == "constant":
            scenario_suffix = f"constant_{self.applied_constant_target}W"
        return f"tilt{self.applied_tilt}_distance{self.applied_distance}_{scenario_suffix}"

    def build_measurement_names(self):
        """
        Returns (shelly_path, tarom_path) based on tilt, distance and scenario.

        Pattern:
          Load (shelly): load_tiltNN_distanceMM_<scenario>.txt
          MPPT (tarom) :  pv_tiltNN_distanceMM_<scenario>.txt
        """
        base = self._build_base_name()
        shelly_name = f"load_{base}.txt"
        tarom_name = f"pv_{base}.txt"

        shelly_path = SHELLY_LOG_DIR / shelly_name
        tarom_path = TAROM_LOG_DIR / tarom_name

        return shelly_path, tarom_path

    def build_labview_measurement_path(self):
        """
        Path passed to the LabVIEW irradiance logger:
        Data/irradiance/poa_tiltNN_distanceMM_<scenario>.txt
        """
        base = self._build_base_name()
        labview_name = f"poa_{base}.txt"
        return IRRADIANCE_LOG_DIR / labview_name

    def update_name_preview(self, *args):
        try:
            shelly_path, tarom_path = self.build_measurement_names()
            self.preview_var.set(
                f"Load: {shelly_path.name}   |   MPPT: {tarom_path.name}"
            )
        except Exception:
            self.preview_var.set("")

    def update_name_preview_and_target_state(self, *args):
        self.update_name_preview(*args)
        self.update_constant_target_state()

    def update_constant_target_state(self):
        state = "normal" if self._scenario_value(self.scenario_var.get()) == "constant" else "disabled"
        self.constant_target_entry.configure(state=state)

    def update_scenario_constant_target_state(self, *_args):
        if hasattr(self, "scenario_constant_entry"):
            state = "normal" if self._scenario_value(self.scenario_control_var.get()) == "constant" else "disabled"
            self.scenario_constant_entry.configure(state=state)

    def set_measurement_parameters(self):
        """Save the current measurement parameters for file naming and refresh
        the file name preview. Does not start or restart any process."""
        try:
            tilt = int(self.tilt_var.get())
            distance = int(self.distance_var.get())
            constant_target = self.get_constant_target()
        except (tk.TclError, ValueError) as error:
            messagebox.showerror("Measurement error", str(error))
            return
        if not 0 <= tilt <= 90:
            messagebox.showerror("Measurement error", "Tilt must be between 0 and 90 degrees.")
            return
        if not 0 <= distance <= 1000:
            messagebox.showerror("Measurement error", "Distance must be between 0 and 1000 cm.")
            return

        self.applied_tilt = tilt
        self.applied_distance = distance
        self.applied_scenario = self._scenario_value(self.scenario_var.get().strip())
        self.applied_constant_target = constant_target
        self.update_name_preview()
        self.status_var.set(
            f"Measurement parameters saved for file naming: tilt={tilt} deg, "
            f"distance={distance} cm, scenario={self._scenario_label(self.applied_scenario)}."
            " Start a logger to begin recording."
        )

    def validate_constant_target(self, proposed_value):
        if proposed_value == "":
            return True
        return proposed_value.isdigit() and int(proposed_value) <= 1800

    def get_constant_target(self):
        try:
            target = int(self.constant_target_var.get())
        except ValueError:
            raise ValueError("Constant load must be an integer from 0 to 1800 W.")
        if not 0 <= target <= 1800:
            raise ValueError("Constant load must be between 0 and 1800 W.")
        return target

    def on_constant_target_changed(self, *_args):
        if self._scenario_value(self.scenario_var.get()) == "constant":
            self.status_var.set("Constant load updated. Start or select Constant load to apply it.")

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

    def schedule_logger_restart(self):
        if self.logger_restart_timer_id is not None:
            self.after_cancel(self.logger_restart_timer_id)
            self.logger_restart_timer_id = None

        now = datetime.now()
        minutes = (now.minute // 15) * 15
        boundary = now.replace(minute=minutes, second=0, microsecond=0).replace(
            second=0, microsecond=0
        ) + timedelta(minutes=15)
        delay_ms = max(1, int((boundary - now).total_seconds() * 1000))
        self.status_var.set(
            f"Scenario changed; logging path switches at {boundary.strftime('%H:%M')}."
        )
        self.logger_restart_timer_id = self.after(delay_ms, self.restart_running_loggers_for_scenario)

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
            self.get_constant_target()
            self.start_shelly_logger()
            self.start_tarom_logger()
            self.upload_github()
            self.start_scenario_controller()
            self.start_labview_logger()
            self.update_start_button_states()
            self.set_measurement_panel_enabled(False)
            self.status_var.set("All scripts started (Load, MPPT, GitHub, controller, LabVIEW).")
        except Exception as e:
            messagebox.showerror("Start ALL error", str(e))

    def stop_loggers(self, turn_off=True):
        if self.all_off_check_id is not None:
            self.after_cancel(self.all_off_check_id)
            self.all_off_check_id = None
        if self.start_timer_id is not None:
            self.after_cancel(self.start_timer_id)
            self.start_timer_id = None
        if self.stop_timer_id is not None:
            self.after_cancel(self.stop_timer_id)
            self.stop_timer_id = None
        if self.logger_restart_timer_id is not None:
            self.after_cancel(self.logger_restart_timer_id)
            self.logger_restart_timer_id = None

        self._stop_process("Load logger", "shelly_proc", self.shelly_running_var)
        self._stop_process("MPPT logger", "tarom_proc", self.tarom_running_var)
        self._stop_process("Scenario controller", "scenario_proc", self.scenario_running_var)
        self._stop_process("GitHub upload", "github_proc", self.github_running_var)
        self._stop_process("All OFF command", "all_off_proc", tk.BooleanVar(value=False))
        self.stop_labview_logger()
        self.stop_scenario_request_processes()
        self.clear_scenario_request_file()
        if turn_off:
            self.start_immediate_all_off()
        self.set_measurement_panel_enabled(True)

    def update_start_button_states(self):
        """
        Disable each logging 'Start' button while its process is running so the
        user cannot start a duplicate/overlapping instance. Also keep the
        combined Load + controller checkbox in sync with both processes.
        """
        running = {
            "start_shelly_ctrl_btn": (self.shelly_proc is not None and self.shelly_proc.poll() is None)
                or (self.scenario_proc is not None and self.scenario_proc.poll() is None),
            "start_tarom_btn": self.tarom_proc is not None and self.tarom_proc.poll() is None,
            "start_github_btn": self.github_proc is not None and self.github_proc.poll() is None,
            "start_labview_btn": self.labview_running_var.get(),
        }
        for attr, is_running in running.items():
            btn = getattr(self, attr, None)
            if btn is not None:
                btn.configure(state="disabled" if is_running else "normal")

        self.load_running_var.set(running["start_shelly_ctrl_btn"])

    def set_measurement_panel_enabled(self, enabled):
        """
        Enable/disable the whole Measurement panel and the Start ALL button.
        When a measurement session is running the user should not be able to
        change the measurement parameters nor start a second session.
        """
        state = "normal" if enabled else "disabled"
        if hasattr(self, "start_all_btn") and self.start_all_btn is not None:
            self.start_all_btn.configure(state=state)
        if hasattr(self, "measurement_frame") and self.measurement_frame is not None:
            for child in self.measurement_frame.winfo_children():
                # Plain tk.Label widgets don't support the "state" option.
                if child.winfo_class() == "Label":
                    continue
                try:
                    child.configure(state=state)
                except tk.TclError:
                    pass

    # --- Individual PS1 actions -------------------------------------

    def start_shelly_logger(self):
        self._stop_process("Load logger", "shelly_proc", self.shelly_running_var)
        shelly_path, _ = self.build_measurement_names()

        self.status_var.set(f"Starting Load logger -> {shelly_path} ...")

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
        self.update_start_button_states()

    def start_tarom_logger(self):
        self._stop_process("MPPT logger", "tarom_proc", self.tarom_running_var)
        _, tarom_path = self.build_measurement_names()

        self.status_var.set(f"Starting MPPT logger -> {tarom_path} ...")

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
        self.update_start_button_states()

    def upload_github(self):
        self._stop_process("GitHub upload", "github_proc", self.github_running_var)

        # Remove any leftover/upload lock so the fresh upload process can always
        # acquire the lock and push immediately, even if a previous run crashed.
        try:
            (SCRIPTS_DIR / "Upload-PVData.lock").unlink(missing_ok=True)
        except OSError:
            pass

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
        self.update_start_button_states()
        self.after(500, self.check_github_process)

    def check_github_process(self):
        if self.github_proc is not None:
            if self.github_proc.poll() is None:
                self.after(500, self.check_github_process)
            else:
                self.github_running_var.set(False)
                self.github_proc = None
                self.update_start_button_states()

    def start_scenario_controller(self):
        """
        Start the long-running Shelly load controller.

        Equivalent to:
        .\\shelly_load_control_scenarios.ps1 -ConfigPath <config path> -Scenario <initial scenario>
        """
        initial_scenario = self.applied_scenario or "all_on"
        constant_target = self.applied_constant_target
        self._stop_process("Scenario controller", "scenario_proc", self.scenario_running_var)
        self.clear_scenario_request_file()

        self.status_var.set(
            f"Starting scenario controller (initial: {initial_scenario})..."
        )

        cmd = [
            "powershell",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(SHELLY_SCENARIO_SCRIPT),
            "-ConfigPath",
            str(SHELLY_SCENARIO_CONFIG),
            "-ScenarioRequestPath",
            str(SCENARIO_REQUEST_PATH),
            "-Scenario",
            initial_scenario,
            "-ConstantTargetW",
            str(constant_target),
        ]

        self.scenario_proc = subprocess.Popen(cmd)
        self.scenario_running_var.set(True)
        self.update_start_button_states()

        self.after(1000, self.check_scenario_controller)

    def check_scenario_controller(self):
        """
        Poll the controller process; update the 'Scenario running' checkbox.
        """
        if self.scenario_proc is not None:
            if self.scenario_proc.poll() is None:
                self.after(1000, self.check_scenario_controller)
            else:
                self.scenario_running_var.set(False)
                self.scenario_proc = None
                self.status_var.set("Scenario controller stopped.")
                self.update_start_button_states()

    def start_shelly_controller(self):
        """
        Combined start: boot the controller first (applies the desired load),
        then start the Shelly logger to record it.
        """
        self.start_scenario_controller()
        self.start_shelly_logger()

    def stop_shelly_controller(self):
        self.stop_scenario_controller()
        self.stop_shelly_logger()
        # "Stop Load + controller" must also shut all the sockets off.
        self._run_all_off_now()

    def is_measurement_running(self):
        """True if any measurement logger process is currently running."""
        return any(
            getattr(self, attr) is not None and getattr(self, attr).poll() is None
            for attr in ("shelly_proc", "tarom_proc")
        )

    def request_scenario_flag(self, flag_name: str, scenario_label: str, immediate: bool = False):
        """
        Fire-and-forget scenario request.

        Updates the applied scenario so loggers restart with the correct file
        name. When a measurement is running the loggers adopt the new file at
        the next 15-minute boundary, unless the request is immediate
        (Turn OFF NOW shuts the sockets straight away).
        """
        if scenario_label == "constant":
            try:
                constant_target = self.get_constant_target()
            except ValueError as error:
                messagebox.showerror("Scenario error", str(error))
                return
            self.applied_constant_target = constant_target

        self.applied_scenario = scenario_label
        self.scenario_var.set(self._scenario_label(scenario_label))
        self.update_name_preview_and_target_state()

        controller_running = (
            self.scenario_proc is not None and self.scenario_proc.poll() is None
        )
        if controller_running:
            self.status_var.set(
                f"Requesting scenario '{self._scenario_label(scenario_label)}' ({flag_name})..."
            )
            cmd = [
                "powershell",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(SHELLY_SCENARIO_SCRIPT),
                "-ConfigPath",
                str(SHELLY_SCENARIO_CONFIG),
                "-ScenarioRequestPath",
                str(SCENARIO_REQUEST_PATH),
                flag_name,
            ]
            if scenario_label == "constant":
                cmd.extend(["-ConstantTargetW", str(self.applied_constant_target)])
            request_proc = subprocess.Popen(cmd)
            self.scenario_request_procs.append(request_proc)
        else:
            self.status_var.set(
                f"Scenario set to {self._scenario_label(scenario_label)}. Start the controller to apply it."
            )

        if self.is_measurement_running():
            if immediate:
                self.restart_running_loggers_for_scenario()
            else:
                self.schedule_logger_restart()

    def on_scenario_selected(self, _event):
        scenario = self._scenario_value(self.scenario_var.get())
        scenario_flags = {
            "all_on": "-SetScenarioAllOn",
            "whole_house": "-SetScenarioWholeHouse",
            "constant": "-SetScenarioConstant1kW",
            "adaptive": "-SetScenarioAdaptive",
        }
        self.request_scenario_flag(scenario_flags[scenario], scenario)

    def on_measurement_parameter_changed(self, *_args):
        self.update_name_preview()

    def request_scenario_from_control(self):
        """
        Apply the scenario profile selected in the Scenario control dropdown.
        """
        scenario = self._scenario_value(self.scenario_control_var.get())
        scenario_flags = {
            "all_on": "-SetScenarioAllOn",
            "whole_house": "-SetScenarioWholeHouse",
            "constant": "-SetScenarioConstant1kW",
            "adaptive": "-SetScenarioAdaptive",
            "all_off": "-SetScenarioAllOff",
        }
        if scenario not in scenario_flags:
            self.status_var.set("Select a valid scenario profile first.")
            return
        if scenario == "all_off":
            self.scenario_all_off()
        else:
            self.request_scenario_flag(scenario_flags[scenario], scenario)

    def scenario_all_off(self):
        self.request_scenario_flag("-SetScenarioAllOff", "all_off", immediate=False)
        self.status_var.set("Turn OFF requested; sockets will switch at the next 15-minute boundary.")

    def _all_off_run_once_cmd(self):
        return [
            "powershell",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(SHELLY_SCENARIO_SCRIPT),
            "-ConfigPath",
            str(SHELLY_SCENARIO_CONFIG),
            "-ScenarioRequestPath",
            str(SCENARIO_REQUEST_PATH),
            "-StatusPath",
            str(SCENARIO_STATUS_PATH),
            "-Scenario",
            "all_off",
            "-RunOnce",
        ]

    def start_immediate_all_off(self):
        self._stop_process("Scenario controller", "scenario_proc", self.scenario_running_var)
        self.status_var.set( "Shutting down: stopping loggers, terminating processes, and turning all loads off...")
        self.all_off_proc = subprocess.Popen(self._all_off_run_once_cmd())
        self.all_off_check_id = self.after(250, self.check_all_off_process)

    def _run_all_off_now(self):
        """
        Turn the sockets off immediately. The controller stays active and the
        GUI keeps running; only the sockets are switched off.
        """
        self.status_var.set("Turning off sockets now...")
        self.all_off_proc = subprocess.Popen(self._all_off_run_once_cmd())
        self.all_off_check_id = self.after(250, self.check_all_off_process)

    def check_all_off_process(self):
        if self.all_off_proc is not None and self.all_off_proc.poll() is None:
            self.all_off_check_id = self.after(250, self.check_all_off_process)
        else:
            self.all_off_check_id = None
            self.all_off_proc = None
            self.status_var.set("All sockets are off.")

    def scenario_all_off_now(self):
        # Turn off sockets immediately; the controller and loggers keep running.
        self.request_scenario_flag("-SetScenarioAllOff", "all_off", immediate=False)
        self._run_all_off_now()

    def show_scenario(self):
        cmd = [
            "powershell",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(SHELLY_SCENARIO_SCRIPT),
            "-ConfigPath",
            str(SHELLY_SCENARIO_CONFIG),
            "-ScenarioRequestPath",
            str(SCENARIO_REQUEST_PATH),
            "-ShowScenario",
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        output = result.stdout.strip() or "No scenario info."
        self.status_var.set("Scenario info requested.")
        messagebox.showinfo("Active scenario", output)

    def show_status(self):
        cmd = [
            "powershell",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(SHELLY_SCENARIO_SCRIPT),
            "-ConfigPath",
            str(SHELLY_SCENARIO_CONFIG),
            "-ScenarioRequestPath",
            str(SCENARIO_REQUEST_PATH),
            "-StatusPath",
            str(SCENARIO_STATUS_PATH),
            "-ShowStatus",
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        output = result.stdout.strip() or "No status info."
        self.status_var.set("Status info requested.")
        messagebox.showinfo("Controller status", output)

    def clear_scenario_request(self):
        cmd = [
            "powershell",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(SHELLY_SCENARIO_SCRIPT),
            "-ConfigPath",
            str(SHELLY_SCENARIO_CONFIG),
            "-ScenarioRequestPath",
            str(SCENARIO_REQUEST_PATH),
            "-ClearScenarioRequest",
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        self.status_var.set("Scenario request cleared.")
        messagebox.showinfo("Scenario request", "Pending scenario request cleared.")

    def clear_scenario_request_file(self):
        try:
            SCENARIO_REQUEST_PATH.unlink(missing_ok=True)
        except OSError as error:
            self.status_var.set(f"Could not clear scenario request: {error}")

    def apply_scenario_script(self):
        """
        Legacy: Call shelly_load_control_scenarios.ps1 -SetScenario -Scenario <value>.
        Uses current scenario selection, matching the file naming.
        """
        scenario = self._scenario_value(self.scenario_var.get())

        self.status_var.set(
            f"Requesting scenario '{self._scenario_label(scenario)}' via load control script..."
        )

        self.scenario_proc = subprocess.Popen(
            [
                "powershell",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(SHELLY_SCENARIO_SCRIPT),
                "-ConfigPath",
                str(SHELLY_SCENARIO_CONFIG),
                "-ScenarioRequestPath",
                str(SCENARIO_REQUEST_PATH),
                "-SetScenario",
                "-Scenario",
                scenario,
                "-ConstantTargetW",
                str(self.get_constant_target()),
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

    def _stop_process(self, label: str, attr_name: str, var: tk.BooleanVar):
        """
        Terminate a single subprocess if running; update checkbox + status.
        """
        proc = getattr(self, attr_name, None)
        if proc is not None and proc.poll() is None:
            try:
                try:
                    subprocess.run(
                        ["taskkill", "/PID", str(proc.pid), "/T", "/F"],
                        check=False,
                        capture_output=True,
                        text=True,
                        timeout=2,
                    )
                    proc.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=1)
                setattr(self, attr_name, None)
                var.set(False)
                self.status_var.set(f"{label} stopped.")
            except Exception as e:
                self.status_var.set(f"Failed to stop {label}: {e}")
        else:
            if proc is not None:
                setattr(self, attr_name, None)
                var.set(False)
            self.status_var.set(f"{label} not running.")
        self.update_start_button_states()

    def stop_shelly_logger(self):
        self._stop_process("Load logger", "shelly_proc", self.shelly_running_var)

    def stop_tarom_logger(self):
        self._stop_process("MPPT logger", "tarom_proc", self.tarom_running_var)

    def stop_scenario_controller(self):
        self._stop_process(
            "Scenario controller", "scenario_proc", self.scenario_running_var
        )

    def stop_github_upload(self):
        self._stop_process("GitHub upload", "github_proc", self.github_running_var)

    def _run_labview_script(self, action, data_path=None):
        cmd = [
            "powershell.exe",
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", str(LABVIEW_LOGGER_SCRIPT),
            "-Action", action,
            "-LabVIEWPath", str(LABVIEW_PATH),
            "-VIPath", str(LABVIEW_VI_PATH),
        ]
        if data_path is not None:
            cmd.extend(["-DataFile", str(data_path)])
        return subprocess.run(cmd, capture_output=True, text=True, check=False)

    def start_labview_logger(self):
        try:
            data_path = self.build_labview_measurement_path()
            if not LABVIEW_LOGGER_SCRIPT.exists():
                raise FileNotFoundError(f"Launcher not found: {LABVIEW_LOGGER_SCRIPT}")
            if not LABVIEW_PATH.exists():
                raise FileNotFoundError(f"LabVIEW.exe not found: {LABVIEW_PATH}")
            if not LABVIEW_VI_PATH.exists():
                raise FileNotFoundError(f"VI not found: {LABVIEW_VI_PATH}")

            result = self._run_labview_script("Start", data_path)
            if result.returncode != 0:
                raise RuntimeError(result.stderr.strip() or result.stdout.strip())

            self.labview_running_var.set(True)
            self.status_var.set(
                f"LabVIEW VI started: {data_path.name}. {result.stdout.strip()}"
            )
        except Exception as error:
            self.labview_running_var.set(False)
            messagebox.showerror("LabVIEW start error", str(error))
        self.update_start_button_states()

    def stop_labview_logger(self):
        try:
            result = self._run_labview_script("Stop")
            if result.returncode != 0:
                raise RuntimeError(result.stderr.strip() or result.stdout.strip())
            self.labview_proc = None
            self.labview_running_var.set(False)
            self.status_var.set(f"LabVIEW VI stopped. {result.stdout.strip()}")
        except Exception as error:
            messagebox.showerror("LabVIEW stop error", str(error))
        self.update_start_button_states()

    def stop_scenario_request_processes(self):
        for process in self.scenario_request_procs:
            if process.poll() is None:
                try:
                    subprocess.run(
                        ["taskkill", "/PID", str(process.pid), "/T", "/F"],
                        check=False,
                        capture_output=True,
                        text=True,
                        timeout=2,
                    )
                except subprocess.TimeoutExpired:
                    process.kill()
        self.scenario_request_procs.clear()

    def restart_running_loggers_for_scenario(self):
        self.logger_restart_timer_id = None
        shelly_running = self.shelly_proc is not None and self.shelly_proc.poll() is None
        tarom_running = self.tarom_proc is not None and self.tarom_proc.poll() is None
        labview_running = self.labview_running_var.get()

        if shelly_running:
            self.stop_shelly_logger()
        if tarom_running:
            self.stop_tarom_logger()
        if labview_running:
            self.stop_labview_logger()
        if shelly_running:
            self.start_shelly_logger()
        if tarom_running:
            self.start_tarom_logger()
        if labview_running:
            # Restart LabVIEW so its poa_*.txt file adopts the new scenario name.
            self.start_labview_logger()

    def read_json_file(self, path: pathlib.Path):
        try:
            with path.open("r", encoding="utf-8-sig") as file:
                return json.load(file)
        except (OSError, json.JSONDecodeError):
            return None

    def open_data_directory(self):
        try:
            subprocess.Popen(["explorer.exe", str(DATA_DIR)])
            self.status_var.set(f"Opened data directory: {DATA_DIR}")
        except OSError as error:
            self.status_var.set(f"Could not open data directory: {error}")

    def open_live_dashboard(self):
        webbrowser.open(DASHBOARD_URL)
        self.status_var.set(f"Opened live dashboard: {DASHBOARD_URL}")

    def open_github_repo(self):
        webbrowser.open(GITHUB_REPO_URL)
        self.status_var.set(f"Opened GitHub repo: {GITHUB_REPO_URL}")

    def get_last_github_push(self):
        """
        Last successful GitHub push time.

        Primary source: the git history of the synced local repo (the upload
        script commits and pushes right after syncing, so the latest commit
        time is effectively the last push time). Falls back to parsing the
        upload log configured in Scripts/scripts/folder-mappings.json.
        """
        repo_dir = None
        log_path = None
        try:
            with (SCRIPTS_DIR / "folder-mappings.json").open("r", encoding="utf-8") as file:
                mappings = json.load(file)
            if mappings.get("RepoDir"):
                repo_dir = pathlib.Path(mappings["RepoDir"])
            if mappings.get("LogFile"):
                log_path = pathlib.Path(mappings["LogFile"])
        except (OSError, json.JSONDecodeError):
            pass

        for candidate in list(dict.fromkeys([repo_dir, REPO_ROOT])):
            if candidate is None:
                continue
            try:
                result = subprocess.run(
                    ["git", "-C", str(candidate), "log", "-1", "--format=%ci"],
                    capture_output=True,
                    text=True,
                    timeout=5,
                )
                if result.returncode == 0 and result.stdout.strip():
                    return result.stdout.strip()
            except (subprocess.SubprocessError, OSError):
                continue

        if log_path is None or not log_path.exists():
            return "Unavailable"

        last_ts = None
        try:
            with log_path.open("r", encoding="utf-8-sig", errors="replace") as file:
                for line in file:
                    if "Sync complete" in line or "First push completed successfully" in line:
                        last_ts = datetime.strptime(line[1:20], "%Y-%m-%d %H:%M:%S")
            if last_ts is None:
                return "Never"
            return last_ts.strftime("%Y-%m-%d %H:%M:%S")
        except (OSError, ValueError):
            return "Unavailable"

    def refresh_scenario_viewer(self):
        status = self.read_json_file(SCENARIO_STATUS_PATH)
        request = self.read_json_file(SCENARIO_REQUEST_PATH)
        dashboard = self.read_json_file(DASHBOARD_VALUES_FILE)
        controller_running = (
            self.scenario_proc is not None and self.scenario_proc.poll() is None
        )

        self.viewer_vars["controller"].set(
            "Running" if controller_running else "Stopped / unavailable"
        )
        active = status.get("active_scenario") if status else None
        # Pending scenario is read directly from the scenario request file
        # (written immediately when a request is made) instead of relying on the
        # controller's asynchronously-written status field, which often stays
        # "None". It is only reported as pending while the requested scenario
        # differs from the active one.
        pending = None
        requested_scenario = request.get("scenario") if request else None
        if requested_scenario and requested_scenario != active:
            pending = self._scenario_label(requested_scenario)
        else:
            status_pending = status.get("pending_scenario") if status else None
            pending = self._scenario_label(status_pending) if status_pending else None
        self.viewer_vars["active"].set(str(active) if active else "Unavailable")
        self.viewer_vars["pending"].set(str(pending) if pending else "None")
        self.viewer_vars["requested_for"].set(str(request.get("requested_for_slot", "Unavailable")) if request else "Unavailable")
        self.viewer_vars["slot"].set(str(status.get("current_slot", "Unavailable")) if status else "Unavailable")
        target = status.get("current_target_w") if status else None
        self.viewer_vars["target"].set(f"{target} W" if target is not None else "Unavailable")
        self.viewer_vars["last_push"].set(self.get_last_github_push())

        # Values sent to the live dashboard (Load + MPPT PV)
        load = dashboard.get("load") if dashboard else None
        pv = dashboard.get("pv") if dashboard else None
        load_w = load.get("load_active_total_w") if load else None
        pv1_w = pv.get("pv1_power_w") if pv else None
        pv2_w = pv.get("pv2_power_w") if pv else None
        pv_total_w = pv.get("pv_power_total_w") if pv else None
        self.viewer_vars["load_w"].set(f"{load_w} W" if load_w is not None else "Unavailable")
        self.viewer_vars["pv1_w"].set(f"{pv1_w} W" if pv1_w is not None else "Unavailable")
        self.viewer_vars["pv2_w"].set(f"{pv2_w} W" if pv2_w is not None else "Unavailable")
        self.viewer_vars["pv_total_w"].set(f"{pv_total_w} W" if pv_total_w is not None else "Unavailable")

        # LabVIEW POA data (written to dashboard_values.json by the labview
        # logger's background poller) - renamed to match the irradiance log.
        sensors = dashboard.get("sensors") if dashboard else None
        sensors_pairs = (
            ("poa_front", "Ge_front"),
            ("poa_rear", "Ge_back"),
            ("tc1", "TC1"),
            ("tc2", "TC2"),
            ("tc3", "TC3"),
            ("tc4", "TC4"),
        )
        for var_key, key in sensors_pairs:
            value = sensors.get(key) if sensors else None
            self.viewer_vars[var_key].set(
                f"{value}" if value is not None else "Unavailable"
            )

        self.viewer_refresh_id = self.after(1500, self.refresh_scenario_viewer)

    def on_close(self):
        if self.start_timer_id is not None:
            self.after_cancel(self.start_timer_id)
            self.start_timer_id = None
        if self.viewer_refresh_id is not None:
            self.after_cancel(self.viewer_refresh_id)
        self.status_var.set("Shutting down: stopping loggers, terminating processes, and turning all loads off...")
        self.stop_loggers()
        self.stop_loggers(turn_off=False)
        self.stop_labview_logger()
        self.destroy()


if __name__ == "__main__":
    app = PVControlApp()
    app.mainloop()