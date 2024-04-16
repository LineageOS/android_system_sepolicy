;; complement CIL file for compatibility between ToT policy and 30.0 vendors.
;; will be compiled along with other normal policy files, on 30.0 vendors.
;;

(typeattribute vendordomain)
(typeattributeset vendordomain ((and (domain) ((not (coredomain))))))

;; TODO: Once 30.0 is no longer supported for vendor images,
;; mlsvendorcompat can be completely from the system policy.
(typeattributeset mlsvendorcompat (and appdomain vendordomain))
(allow mlsvendorcompat app_data_file (dir (ioctl read write create getattr setattr lock rename open watch watch_reads add_name remove_name reparent search rmdir)))
(allow mlsvendorcompat app_data_file (file (ioctl read write create getattr setattr lock append map unlink rename open watch watch_reads)))
(allow mlsvendorcompat privapp_data_file (dir (ioctl read write create getattr setattr lock rename open watch watch_reads add_name remove_name reparent search rmdir)))
(allow mlsvendorcompat privapp_data_file (file (ioctl read write create getattr setattr lock append map unlink rename open watch watch_reads)))

;; permission for devices (older than S) where debugfs restriction doesn't apply.
(typeattribute debugfs_file_type)
(typeattributeset debugfs_file_type (and debugfs_type file_type))
(typeattribute debugfs_fs_type)
(typeattributeset debugfs_fs_type (and debugfs_type fs_type))

(allow dumpstate debugfs (file (ioctl read getattr lock map open watch watch_reads)))
(allow dumpstate debugfs_mmc (file (ioctl read getattr lock map open watch watch_reads)))
(allow dumpstate debugfs_wakeup_sources (file (ioctl read getattr lock map open watch watch_reads)))
(auditallow dumpstate debugfs (file (ioctl read getattr lock map open watch watch_reads)))

(allow init debugfs (dir (getattr relabelfrom)))
(allow init debugfs (file (getattr relabelfrom)))
(allow init debugfs (lnk_file (getattr relabelfrom)))
(allow init debugfs_file_type (file (create getattr open read write setattr relabelfrom unlink map)))
(allow init debugfs_fs_type (filesystem (mount remount unmount getattr relabelfrom associate quotamod quotaget watch)))
(allow init debugfs_type (dir (getattr relabelto)))
(allow init debugfs_type (file (getattr relabelto)))
(allow init debugfs_type (lnk_file (getattr relabelto)))

(allow system_server debugfs_wakeup_sources (file (ioctl read getattr lock map open watch watch_reads)))

(allow vendor_init debugfs_file_type (file (create getattr open read write setattr relabelfrom unlink map)))
(allow vendor_init debugfs_fs_type (file (open read setattr map)))
