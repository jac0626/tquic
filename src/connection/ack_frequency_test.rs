use crate::connection::tests::TestPair;
use crate::Config;
#[test]
fn ack_frequency_negotiation() {
    let mut client_config = Config::new().unwrap();
    client_config.enable_ack_frequency(1000);
    let mut server_config = Config::new().unwrap();
    server_config.enable_ack_frequency(2000);

    let cert_file = "fuzz/conf/cert.crt";
    let key_file = "fuzz/conf/cert.key";
    let protos = vec![b"h3".to_vec()];
    let server_tls_config =
        crate::TlsConfig::new_server_config(cert_file, key_file, protos.clone(), false).unwrap();
    server_config.set_tls_config(server_tls_config);

    let client_tls_config = crate::TlsConfig::new_client_config(protos, false).unwrap();
    client_config.set_tls_config(client_tls_config);

    let mut test_pair = TestPair::new(&mut client_config, &mut server_config).unwrap();
    test_pair.handshake().unwrap();

    assert_eq!(
        test_pair.client.peer_transport_params().min_ack_delay,
        Some(2000)
    );
    assert_eq!(
        test_pair.server.peer_transport_params().min_ack_delay,
        Some(1000)
    );
}
