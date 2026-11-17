import os

/// Společný logger daemona. Čtení: `log stream --predicate 'subsystem == "cz.stayup.StayUp.helper"'`.
let helperLog = Logger(subsystem: "cz.stayup.StayUp.helper", category: "daemon")
