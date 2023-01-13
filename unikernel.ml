(* (c) 2018 Hannes Mehnert, all rights reserved *)

open Lwt.Infix

open Dns

let err_to_exit ~prefix = function
  | Ok x -> x
  | Error `Msg msg ->
    Logs.err (fun m -> m "error in %s: %s" prefix msg);
    exit Mirage_runtime.argument_error

module Client (C : Mirage_console.S) (R : Mirage_random.S) (P : Mirage_clock.PCLOCK) (M : Mirage_clock.MCLOCK) (T : Mirage_time.S) (S : Tcpip.Stack.V4V6) (Management : Tcpip.Stack.V4V6) = struct
  module Acme = LE.Make(T)(S)

  module DNS = Dns_client_mirage.Make(R)(T)(M)(P)(S)

  module D = Dns_mirage.Make(S)
  module DS = Dns_server_mirage.Make(P)(M)(T)(S)

  module Nss = Ca_certs_nss.Make(P)

  let inc =
    let counters =
      Mirage_monitoring.counter_metrics ~f:(fun x -> x) "letsencrypt"
    in
    fun name ->
      Metrics.add counters (fun x -> x) (fun d -> d name)

  (* act as a hidden dns secondary and receive notifies, sweep through the zone for signing requests without corresponding (non-expired) certificate

     requires transfer and update keys

     on startup or when a notify is received, we fold over all TLSA records
      if there's a single csr and no valid and public-key matching cert get a cert from let's encrypt
      let's encrypt (http[s]) and dns challenge is used
      resulting certificate is nsupdated to primary dns

     Acme.initialise is done just at boottime

     then zone transfer and notifies is acted upon

     for each new tlsa record where selector = private and the content can be
       parsed as csr with a domain name we have keys for (or update uses the
       right key)
 *)

  let valid_and_matches_csr csr cert =
    (* parse csr, parse cert: match public keys, match validity of cert *)
    match
      X509.Signing_request.decode_der csr.Tlsa.data,
      X509.Certificate.decode_der cert.Tlsa.data
    with
    | Ok csr, Ok cert ->
      let now_plus_two_weeks =
        let (days, ps) = P.now_d_ps () in
        Ptime.v (days + 14, ps)
      and now = Ptime.v (P.now_d_ps ())
      in
      if Dns_certify.cert_matches_csr ~until:now_plus_two_weeks now csr cert then
        None
      else
        Some csr
    | Ok csr, Error `Msg e ->
      Logs.err (fun m -> m "couldn't parse certificate %s, requesting new one" e);
      Some csr
    | Error `Msg e, _ ->
      Logs.err (fun m -> m "couldn't parse csr %s, nothing to see here" e) ;
      None

  let contains_csr_without_certificate name tlsas =
    let csrs = Rr_map.Tlsa_set.filter Dns_certify.is_csr tlsas in
    if Rr_map.Tlsa_set.cardinal csrs <> 1 then begin
      Logs.warn (fun m -> m "no or multiple signing requests found for %a (skipping)"
                    Domain_name.pp name);
      None
    end else
      let csr = Rr_map.Tlsa_set.choose csrs in
      let certs = Rr_map.Tlsa_set.filter Dns_certify.is_certificate tlsas in
      match Rr_map.Tlsa_set.cardinal certs with
      | 0 ->
        Logs.warn (fun m -> m "no certificate found for %a, requesting"
                      Domain_name.pp name);
        begin match X509.Signing_request.decode_der csr.Tlsa.data with
          | Ok csr -> Some csr
          | Error `Msg e ->
            Logs.warn (fun m -> m "couldn't parse CSR %s" e);
            None
        end
      | 1 ->
        begin
          let cert = Rr_map.Tlsa_set.choose certs in
          match valid_and_matches_csr csr cert with
          | None ->
            Logs.debug (fun m -> m "certificate already exists for signing request %a, skipping"
                           Domain_name.pp name);
            None
          | Some csr ->
            Logs.warn (fun m -> m "certificate not valid or doesn't match signing request %a, requesting"
                          Domain_name.pp name);
            Some csr
        end
      | _ ->
        Logs.err (fun m -> m "multiple certificates found for %a, skipping"
                     Domain_name.pp name);
        None

  let mem_flight, add_flight, remove_flight =
    (* TODO use a map with number of attempts *)
    let in_flight = ref Domain_name.Set.empty in
    (fun x -> Domain_name.Set.mem x !in_flight),
    (fun n ->
       Logs.info (fun m -> m "adding %a to in_flight" Domain_name.pp n);
       in_flight := Domain_name.Set.add n !in_flight),
    (fun n ->
       Logs.info (fun m -> m "removing %a from in_flight" Domain_name.pp n);
       in_flight := Domain_name.Set.remove n !in_flight)

  let send_dns, recv_dns =
    let flow = ref None in
    (fun stack data ->
       let dns_server = Key_gen.dns_server ()
       and port = Key_gen.port ()
       in
       Logs.debug (fun m -> m "writing to %a" Ipaddr.pp dns_server) ;
       let tcp = S.tcp stack in
       let rec send again =
         match !flow with
         | None ->
           if again then
             S.TCP.create_connection tcp (dns_server, port) >>= function
             | Error e ->
               Logs.err (fun m -> m "failed to create connection to NS: %a" S.TCP.pp_error e) ;
               Lwt.return (Error (`Msg (Fmt.to_to_string S.TCP.pp_error e)))
             | Ok f -> flow := Some (D.of_flow f) ; send false
           else
             Lwt.return_error (`Msg "couldn't reach authoritative nameserver")
         | Some f ->
           D.send_tcp (D.flow f) data >>= function
           | Error () -> flow := None ; send again
           | Ok () -> Lwt.return_ok ()
       in
       send true),
    (fun () ->
       (* we expect a single reply! *)
       match !flow with
       | None -> Lwt.return_error (`Msg "no TCP flow")
       | Some f ->
         D.read_tcp f >|= function
         | Ok data -> Ok data
         | Error () -> Error (`Msg "error while reading from flow"))

  module Cstruct_set = Set.Make (struct
      type t = Cstruct.t
      let compare = Cstruct.compare
    end)

  let request_certificate stack (keyname, keyzone, dnskey) server le ctx ~tlsa_name csr =
    inc "requesting certificate";
    if mem_flight tlsa_name then
      Logs.err (fun m -> m "request with %a already in-flight"
                   Domain_name.pp tlsa_name)
    else begin
      Logs.info (fun m -> m "running let's encrypt service for %a"
                    Domain_name.pp tlsa_name);
      add_flight tlsa_name;
      (* request new cert in async *)
      Lwt.async (fun () ->
          let sleep n = T.sleep_ns (Duration.of_sec n) in
          let now () = Ptime.v (P.now_d_ps ()) in
          let id = Randomconv.int16 R.generate in
          let solver = Letsencrypt_dns.nsupdate ~proto:`Tcp id now (send_dns stack) ~recv:recv_dns ~zone:keyzone ~keyname dnskey in
          Acme.sign_certificate ~ctx solver le sleep csr >>= function
          | Error (`Msg e) ->
            Logs.err (fun m -> m "error %s while signing %a" e Domain_name.pp tlsa_name);
            remove_flight tlsa_name;
            Lwt.return_unit
          | Ok [] ->
            Logs.err (fun m -> m "received an empty certificate chain for %a" Domain_name.pp tlsa_name);
            remove_flight tlsa_name;
            Lwt.return_unit
          | Ok (cert::cas) ->
            inc "provisioned certificate";
            Logs.info (fun m -> m "certificate received for %a" Domain_name.pp tlsa_name);
            match Dns_trie.lookup tlsa_name Rr_map.Tlsa (Dns_server.Secondary.data server) with
            | Error e ->
              Logs.err (fun m -> m "lookup error for tlsa %a: %a (expected the signing request!)"
                           Domain_name.pp tlsa_name Dns_trie.pp_e e);
              remove_flight tlsa_name;
              Lwt.return_unit
            | Ok (_, tlsas) ->
              (* from tlsas, we need to remove the end entity certificates *)
              (* also potentially all CAs that are not part of cas *)
              (* we should add the new certificate and potentially CAs *)
              let ca_set = Cstruct_set.of_list (List.map X509.Certificate.encode_der cas) in
              let to_remove, cas_to_add =
                Rr_map.Tlsa_set.fold (fun tlsa (to_rm, to_add) ->
                    if Dns_certify.is_ca_certificate tlsa then
                      if Cstruct_set.mem tlsa.Tlsa.data to_add then
                        to_rm, Cstruct_set.remove tlsa.Tlsa.data to_add
                      else
                        tlsa :: to_rm, to_add
                    else if Dns_certify.is_certificate tlsa then
                      tlsa :: to_rm, to_add
                    else
                      to_rm, to_add)
                  tlsas ([], ca_set)
              in
              let update =
                let add =
                  let tlsas =
                    let cas = List.map Dns_certify.ca_certificate (Cstruct_set.elements cas_to_add) in
                    Rr_map.Tlsa_set.of_list (Dns_certify.certificate cert :: cas)
                  in
                  Packet.Update.Add Rr_map.(B (Tlsa, (3600l, tlsas)))
                and remove =
                  List.map (fun tlsa ->
                      Packet.Update.Remove_single Rr_map.(B (Tlsa, (0l, Tlsa_set.singleton tlsa))))
                    to_remove
                in
                let update = Domain_name.Map.singleton tlsa_name (remove @ [ add ]) in
                (Domain_name.Map.empty, update)
              and zone = Packet.Question.create keyzone Rr_map.Soa
              and header = (Randomconv.int16 R.generate, Packet.Flags.empty)
              in
              let packet = Packet.create header zone (`Update update) in
              match Dns_tsig.encode_and_sign ~proto:`Tcp packet (now ()) dnskey keyname with
              | Error s ->
                remove_flight tlsa_name;
                Logs.err (fun m -> m "Error %a while encoding and signing %a"
                             Dns_tsig.pp_s s Domain_name.pp tlsa_name);
                Lwt.return_unit
              | Ok (data, mac) ->
                send_dns stack data >>= function
                | Error (`Msg e) ->
                  remove_flight tlsa_name;
                  Logs.err (fun m -> m "error %s while sending nsupdate %a"
                               e Domain_name.pp tlsa_name);
                  Lwt.return_unit
                | Ok () ->
                  recv_dns () >|= function
                  | Error (`Msg e) ->
                    remove_flight tlsa_name;
                    Logs.err (fun m -> m "error %s while reading DNS %a"
                                 e Domain_name.pp tlsa_name)
                  | Ok data ->
                    remove_flight tlsa_name;
                    match Dns_tsig.decode_and_verify (now ()) dnskey keyname ~mac data with
                    | Error e ->
                      Logs.err (fun m -> m "error %a while decoding nsupdate answer %a"
                                   Dns_tsig.pp_e e Domain_name.pp tlsa_name)
                    | Ok (res, _, _) ->
                      match Packet.reply_matches_request ~request:packet res with
                      | Ok _ -> inc "uploaded certificate"
                      | Error e ->
                        (* TODO: if badtime, adjust our time (to the other time) and resend ;) *)
                        Logs.err (fun m -> m "invalid reply %a for %a, got %a"
                                     Packet.pp_mismatch e Packet.pp packet
                                     Packet.pp res))
    end

  module Monitoring = Mirage_monitoring.Make(T)(P)(Management)
  module Syslog = Logs_syslog_mirage.Udp(C)(P)(Management)

  let start c _random _pclock _mclock _ stack management =
    let hostname = Key_gen.name () in
    (match Key_gen.syslog () with
     | None -> Logs.warn (fun m -> m "no syslog specified, dumping on stdout")
     | Some ip -> Logs.set_reporter (Syslog.create c management ip ~hostname ()));
    (match Key_gen.monitor () with
     | None -> Logs.warn (fun m -> m "no monitor specified, not outputting statistics")
     | Some ip -> Monitoring.create ~hostname ip management);
    let keyname, keyzone, dnskey =
      let keyname, dnskey =
        err_to_exit ~prefix:"couldn't parse dnskey"
          (Dnskey.name_key_of_string (Key_gen.dns_key ()))
      in
      let idx =
        err_to_exit ~prefix:"dnskey is not an update key"
          (Option.to_result
             ~none:(`Msg "couldn't find _update label")
             (Domain_name.find_label keyname (function "_update" -> true | _ -> false)))
      in
      let amount = succ idx in
      let zone = Domain_name.(host_exn (drop_label_exn ~amount keyname)) in
      Logs.app (fun m -> m "using key %a for zone %a" Domain_name.pp keyname Domain_name.pp zone);
      keyname, zone, dnskey
    in
    let dns_state = ref
        (Dns_server.Secondary.create ~primary:(Key_gen.dns_server ()) ~rng:R.generate
           ~tsig_verify:Dns_tsig.verify ~tsig_sign:Dns_tsig.sign [ keyname, dnskey ])
    in
    let account_key =
      let key_type =
        err_to_exit
          ~prefix:"cannot decode key type"
          (X509.Key_type.of_string (Key_gen.account_key_type ()))
      in
      err_to_exit
        ~prefix:"couldn't generate account key"
        (X509.Private_key.of_string ~bits:(Key_gen.account_bits ()) key_type (Key_gen.account_key_seed ()))
    in
    let endpoint =
      if Key_gen.production () then begin
        Logs.warn (fun m -> m "production environment - take care what you do");
        Letsencrypt.letsencrypt_production_url
      end else begin
        Logs.warn (fun m -> m "staging environment - test use only");
        Letsencrypt.letsencrypt_staging_url
      end
    in
    let email = Key_gen.email () in
    let ctx =
      let gethostbyname dns domain_name =
        DNS.gethostbyname dns domain_name >|= function
        | Error _ as e -> e
        | Ok ipv4 -> Ok (Ipaddr.V4 ipv4)
      in
      Acme.ctx ~gethostbyname
        ~authenticator:(Result.get_ok (Nss.authenticator ()))
        (DNS.create stack) stack
    in
    Acme.initialise ~ctx ~endpoint ?email account_key >>= fun r ->
    let le = err_to_exit ~prefix:"couldn't initialize ACME" r in
    Logs.info (fun m -> m "initialised lets encrypt");
    let on_update ~old:_ t =
      inc "on update";
      dns_state := t;
      (* what to do here?
         foreach TLSA record (can as well just do all for now), check whether
         there is a CSR without a valid certificate: if not, request a certificate *)
      let trie = Dns_server.Secondary.data t in
      Dns_trie.fold Dns.Rr_map.Tlsa trie
        (fun name (_, tlsas) () ->
           if Dns_certify.is_name name then
             match contains_csr_without_certificate name tlsas with
             | None -> Logs.debug (fun m -> m "not interesting (does not contain CSR without valid certificate) %a" Domain_name.pp name)
             | Some csr -> request_certificate stack (keyname, keyzone, dnskey) t le ctx ~tlsa_name:name csr
           else
             Logs.debug (fun m -> m "name not interesting %a" Domain_name.pp name)) ();
      Lwt.return_unit
    in
    Lwt.async (fun () ->
        let rec forever () =
          T.sleep_ns (Duration.of_day 1) >>= fun () ->
          on_update ~old:(Dns_server.Secondary.data !dns_state) !dns_state >>= fun () ->
          forever ()
        in
        forever ());
    DS.secondary ~on_update stack !dns_state ;
    S.listen stack
end
