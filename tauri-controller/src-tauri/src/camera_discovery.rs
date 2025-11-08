//! mDNS/Bonjour camera discovery

use anyhow::{Context, Result};
use mdns_sd::{ServiceDaemon, ServiceEvent};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

use crate::models::DiscoveredCamera;

const SERVICE_TYPE: &str = "_avolocam._tcp.local.";

pub struct CameraDiscovery {
    daemon: ServiceDaemon,
    discovered: Arc<RwLock<HashMap<String, DiscoveredCamera>>>,
}

impl CameraDiscovery {
    pub fn new() -> Result<Self> {
        let daemon = ServiceDaemon::new()
            .context("Failed to create mDNS service daemon")?;

        Ok(Self {
            daemon,
            discovered: Arc::new(RwLock::new(HashMap::new())),
        })
    }

    /// Start continuous mDNS browsing
    pub async fn start_browsing(&self) -> Result<()> {
        let receiver = self.daemon.browse(SERVICE_TYPE)
            .context("Failed to start mDNS browse")?;

        let discovered = self.discovered.clone();

        // Spawn background task to process mDNS events
        tokio::spawn(async move {
            while let Ok(event) = receiver.recv_async().await {
                match event {
                    ServiceEvent::ServiceResolved(info) => {
                        log::info!("Discovered camera: {}", info.get_fullname());

                        // Extract information
                        let alias = info.get_fullname()
                            .trim_end_matches(SERVICE_TYPE)
                            .trim_end_matches('.')
                            .to_string();

                        // Get IP address
                        let ip = if let Some(addr) = info.get_addresses().iter().next() {
                            addr.to_string()
                        } else {
                            log::warn!("No IP address found for {}", alias);
                            continue;
                        };

                        let port = info.get_port();

                        // Parse TXT records
                        let mut txt_records = HashMap::new();
                        for prop in info.get_properties().iter() {
                            if let Some(val) = prop.val() {
                                txt_records.insert(
                                    prop.key().to_string(),
                                    String::from_utf8_lossy(val).to_string(),
                                );
                            }
                        }

                        let camera = DiscoveredCamera {
                            alias: alias.clone(),
                            ip,
                            port,
                            txt_records,
                        };

                        // Add to discovered list
                        discovered.write().await.insert(alias, camera);
                    }
                    ServiceEvent::ServiceRemoved(_, fullname) => {
                        log::info!("Camera removed: {}", fullname);

                        let alias = fullname
                            .trim_end_matches(SERVICE_TYPE)
                            .trim_end_matches('.')
                            .to_string();

                        discovered.write().await.remove(&alias);
                    }
                    ServiceEvent::SearchStarted(_) => {
                        log::debug!("mDNS search started");
                    }
                    ServiceEvent::SearchStopped(_) => {
                        log::debug!("mDNS search stopped");
                    }
                    ServiceEvent::ServiceFound(_, _) => {
                        // Ignore, we handle ServiceResolved
                    }
                }
            }

            log::warn!("mDNS discovery loop ended");
        });

        Ok(())
    }

    /// Get currently discovered cameras
    pub async fn get_discovered(&self) -> Vec<DiscoveredCamera> {
        self.discovered.read().await.values().cloned().collect()
    }

    /// Stop browsing
    pub fn stop(&self) {
        self.daemon.stop_browse(SERVICE_TYPE).ok();
    }
}

impl Drop for CameraDiscovery {
    fn drop(&mut self) {
        self.stop();
    }
}
