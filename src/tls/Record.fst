module Record

(* (optional) encryption and processing of the outer (untrusted) record format *)

open FStar.Seq
open Platform.Bytes
open Platform.Error

open TLSError
open TLSInfo
open TLSConstants
open Range
open Content


// Consider merging some of this module with Content?

// ------------------------outer packet format -------------------------------

// the "outer" header has the same format for all versions of TLS
// but TLS 1.3 fakes its content type and protocol version.

type header = b:lbytes 5 // for all TLS versions

let fake = ctBytes Application_data @| versionBytes TLS_1p0 

// this is the outer packet; the *caller* should switch from 1.3 to 1.0 whenever data is encrypted.
let makePacket ct ver (data: b:bytes { repr_bytes (length b) <= 2}) =
//    (if ver = TLS_1p3 then fake else (ctBytes ct @| versionBytes ver))
      ctBytes ct 
   @| versionBytes ver
   @| bytes_of_int 2 (length data) 
   @| data 


val parseHeader: h5:header -> Tot (result (contentType 
                                         * protocolVersion 
                                         * l:nat { l <= max_TLSCiphertext_fragment_length}))
let parseHeader (h5:header) =
    let (ct1,b4)   = Platform.Bytes.split h5 1 in
    let (pv2,len2) = Platform.Bytes.split b4 2 in
    match parseCT ct1 with
    | Error z -> Error z
    | Correct ct ->
      match TLSConstants.parseVersion pv2 with
      | Error z -> Error z
      | Correct pv ->
          let len = int_of_bytes len2 in
          if len <= 0 || len > max_TLSCiphertext_fragment_length 
          then Error(AD_illegal_parameter, perror __SOURCE_FILE__ __LINE__ "Wrong fragment length")
          else correct(ct,pv,len)

(* TODO, possibly a parameter from dispatch *)
assume val is_Null: id -> Tot bool

// hopefully we only care about the writer, not the cn state
// the postcondition is of the form
//   authId i ==> f is added to the writer log
let recordPacketOut (i:StatefulLHAE.id) (wr:StatefulLHAE.writer i) (pv: protocolVersion) f =
    let ct, rg = Content.ct_rg i f in
    let payload =
      if is_Null i
      then Content.repr i f
      else
        let ad = StatefulPlain.makeAD i ct in
        let f = StatefulPlain.assert_is_plain i ad rg f in
        StatefulLHAE.encrypt #i wr ad rg f
    in
    makePacket ct pv payload


(*** networking (floating) ***)

effect EXT (a:Type) = ST a
  (requires (fun _ -> True)) 
  (ensures (fun h0 _ h1 -> modifies Set.empty h0 h1))

val tcp_recv: Platform.Tcp.networkStream -> max:nat -> EXT (optResult string (b:bytes {length b <= max}))
let tcp_recv = Platform.Tcp.recv


private val really_read_rec: b:bytes -> Platform.Tcp.networkStream -> l:nat -> EXT (result (lbytes (l+length b)))

let rec really_read_rec prev tcp len = 
    if len = 0 
    then Correct prev
    else 
      match Platform.Tcp.recv tcp len with
      | Correct b -> 
            let lb = length b in
      	    if lb = len then Correct(prev @| b)
      	    else really_read_rec (prev @| b) tcp (len - lb)
      | Error e -> Error(AD_internal_error,e)

private let really_read = really_read_rec empty_bytes

val read: Platform.Tcp.networkStream -> protocolVersion -> 
  EXT (result (contentType * protocolVersion * b:bytes { length b <= max_TLSCiphertext_fragment_length}))

// in the spirit of TLS 1.3, we ignore the outer protocol version (see appendix C):
// our server never treats the ClientHello's record pv as its minimum supported pv;
// our client never checks the consistency of the server's record pv.
// (see earlier versions for the checks we used to perform)

let read tcp pv =
  match really_read tcp 5 with 
  | Correct header -> (
      match parseHeader header with  
      | Correct (ct,pv,len) -> (
         match really_read tcp len with
         | Correct payload  -> Correct (ct,pv,payload)
         | Error e          -> Error e )
      | Error e             -> Error e )
  | Error e                 -> Error e


(* TODO
let recordPacketIn i (rd:StatefulLHAE.reader i) ct payload =
    if is_Null i
    then
      let rg = Range.point (length payload) in
      let msg = Content.mk_fragment i ct rg payload in
      Correct (rg,msg)
    else
      let ad = StatefulPlain.makeAD i ct in
      let r = StatefulLHAE.decrypt #i #ad rd payload in
      match r with
      | Some f -> Correct f
      | None   -> Error("bad decryption")
*)




(*
// replaced by StatefulLHAE's state?
type ConnectionState =
    | NullState
    | SomeState of TLSFragment.history * StatefulLHAE.state

let someState (e:epoch) (rw:rw) h s = SomeState(h,s)

type sendState = ConnectionState
type recvState = ConnectionState

let initConnState (e:epoch) (rw:rw) s =
  let i = mk_id e in
  let h = TLSFragment.emptyHistory e in
  someState e rw h s

let nullConnState (e:epoch) (rw:rw) = NullState
*)

(*
let history (e:epoch) (rw:rw) s =
    match s with
    | NullState ->
        let i = mk_id e in
        TLSFragment.emptyHistory e
    | SomeState(h,_) -> h
*)
