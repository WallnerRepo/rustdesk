//! Authenticate the app's loopback clients before opening a remote Herdr pipe.
//! Tokens exist only while their exclusively bound listener is alive. A process
//! that squats on a closed port can therefore only capture an expired token.
use hbb_common::{
    lazy_static::lazy_static,
    sodiumoxide::utils::memcmp,
    tokio::{io::AsyncReadExt, net::TcpStream, time::timeout},
};
#[cfg(any(target_os = "android", target_os = "ios", test))]
use hbb_common::{bail, ResultType};
use std::{collections::HashMap, sync::Mutex, time::Duration};

lazy_static! {
    static ref TOKENS: Mutex<HashMap<i32, (String, String)>> = Mutex::new(HashMap::new());
}

pub fn token(port: i32, peer_id: &str) -> String {
    TOKENS
        .lock()
        .unwrap()
        .get(&port)
        .filter(|(owner, _)| owner == peer_id)
        .map(|(_, secret)| secret.clone())
        .unwrap_or_default()
}

#[cfg(any(target_os = "android", target_os = "ios", test))]
pub fn require_secure_tunnel(secured: bool, host: &str, port: i32) -> ResultType<()> {
    if !secured && host == "127.0.0.1" && matches!(port, 8375 | 8378 | 8379) {
        bail!("Herdr requires an authenticated encrypted RustDesk connection");
    }
    Ok(())
}

pub struct ListenerAuth {
    port: i32,
    secret: String,
}

impl ListenerAuth {
    // Call only AFTER the exclusive bind succeeds; never publish a token for
    // a port another process owns. The guard must outlive all listener accepts.
    pub fn new(port: i32, peer_id: String) -> Self {
        let secret = format!(
            "{}{}",
            uuid::Uuid::new_v4().simple(),
            uuid::Uuid::new_v4().simple()
        );
        TOKENS.lock().unwrap().insert(port, (peer_id, secret.clone()));
        Self { port, secret }
    }

    pub async fn accepts(&self, socket: &mut TcpStream) -> bool {
        let mut supplied = [0u8; 64];
        matches!(
            timeout(Duration::from_secs(1), socket.read_exact(&mut supplied)).await,
            Ok(Ok(_))
        ) && memcmp(&supplied, self.secret.as_bytes())
    }
}

impl Drop for ListenerAuth {
    fn drop(&mut self) {
        let mut tokens = TOKENS.lock().unwrap();
        if tokens.get(&self.port).map(|(_, secret)| secret) == Some(&self.secret) {
            tokens.remove(&self.port);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use hbb_common::tokio::{io::AsyncWriteExt, net::TcpListener};

    #[test]
    fn herdr_refuses_an_unsecured_remote_tunnel() {
        assert!(require_secure_tunnel(false, "127.0.0.1", 8375).is_err());
        assert!(require_secure_tunnel(true, "127.0.0.1", 8375).is_ok());
        assert!(require_secure_tunnel(false, "127.0.0.1", 22).is_ok());
    }

    #[tokio::test]
    async fn only_authenticated_local_clients_reach_the_http_stream() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let guard = ListenerAuth::new(i32::from(addr.port()), "peer-a".into());
        assert!(token(i32::from(addr.port()), "peer-b").is_empty());
        for valid in [false, true] {
            let mut client = TcpStream::connect(addr).await.unwrap();
            let (mut server, _) = listener.accept().await.unwrap();
            let credential = if valid {
                token(i32::from(addr.port()), "peer-a")
            } else {
                "x".repeat(64)
            };
            client.write_all(credential.as_bytes()).await.unwrap();
            client.write_all(b"GET /").await.unwrap();
            assert_eq!(guard.accepts(&mut server).await, valid);
            if valid {
                let mut request = [0u8; 5];
                server.read_exact(&mut request).await.unwrap();
                assert_eq!(&request, b"GET /");
            }
        }
        let old = token(i32::from(addr.port()), "peer-a");
        drop(guard);
        assert!(token(i32::from(addr.port()), "peer-a").is_empty());
        let replacement = ListenerAuth::new(i32::from(addr.port()), "peer-a".into());
        assert_ne!(token(i32::from(addr.port()), "peer-a"), old);
        drop(replacement);
    }
}
