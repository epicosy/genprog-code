(*
 * Program Repair Prototype (v2)
 *
 * Program Representation -- text .s assembly file
 *
 * compiled .s assembly files, as produced with gcc -S
 *
 *)

open Printf
open Global
open Rep

(*************************************************************************
 *************************************************************************
               ASM Representation - Compiled Assembly Programs
 *************************************************************************
 *************************************************************************)

let asm_sample_runs = ref 100
let _ =
  options := !options @
  [
    "--asm-sample-runs",
    Arg.Set_int asm_sample_runs,
    "X Execute X runs of the test suite while sampling with oprofile."
  ]

let asmRep_version = "2"

class asmRep = object (self : 'self_type)

  inherit [string list] faultlocRepresentation as super
  (* TODO: implement faultlocRepresentation to apply lines of memory addresses *)

  val base = ref [| (* array of string lists *) |]

  val range = ref [ (* beginning and ends of code sections *) ]

  method atom_to_str slist =
    let b = Buffer.create 255 in
    List.iter (fun s -> Printf.bprintf b "%S" s) slist ;
    Buffer.contents b

  (* make a fresh copy of this variant *)
  method copy () : 'self_type =
    let super_copy : 'self_type = super#copy () in
    super_copy#internal_copy ()

  (* being sure to update our local instance variables *)
  method internal_copy () : 'self_type =
    {<
      base  = ref (Global.copy !base)  ;
      range = ref (Global.copy !range) ;
    >}

  method from_source (filename : string) = begin
    let lst = ref [] in
    let fin = open_in filename in
    (try while true do
      let line = input_line fin in
      lst := [line] :: !lst
    done with _ -> close_in fin) ;
    base := Array.of_list ([] :: (List.rev !lst)) ;
    let beg_points = ref [] in
    let end_points = ref [] in
      (* beg/end start and stop code sections respectively *)
    let beg_regx = Str.regexp "^[0-9a-zA-Z_]+:$" in
    let end_regx = Str.regexp "^[ \t]+\\.size.*" in
    let in_code_p = ref false in
      Array.iteri (fun i line ->
                     if ( i > 0 ) then begin
                       if !in_code_p then begin
                         if (Str.string_match end_regx (List.hd line) 0) then begin
                           in_code_p := false ;
                           end_points := i :: !end_points ;
                         end
                       end else begin
                         if (Str.string_match beg_regx (List.hd line) 0) then begin
                           in_code_p := true ;
                           beg_points := i :: !beg_points ;
                         end
                       end
                     end
                  ) !base ;
      if !in_code_p then
        end_points := (Array.length !base) :: !end_points ;
      range := List.rev (List.combine !beg_points !end_points) ;
  end

  method output_source source_name = begin
    let fout = open_out source_name in
    Array.iteri (fun i line_list ->
      if i > 0 then begin
        List.iter (fun line ->
          Printf.fprintf fout "%s\n" line
        ) line_list
      end
    ) !base ;
    close_out fout ;
    let digest = Digest.file source_name in
    already_sourced := Some([source_name],[digest]) ;
  end

  method save_binary ?out_channel (filename : string) = begin
    let fout =
      match out_channel with
      | Some(v) -> v
      | None -> open_out_bin filename
    in
    Marshal.to_channel fout (asmRep_version) [] ;
    Marshal.to_channel fout (!range) [] ;
    Marshal.to_channel fout (!base) [] ;
    super#save_binary ~out_channel:fout filename ;
    debug "asm: %s: saved\n" filename ;
    if out_channel = None then close_out fout
  end

  (* load in serialized state *)
  method load_binary ?in_channel (filename : string) = begin
    let fin =
      match in_channel with
      | Some(v) -> v
      | None -> open_in_bin filename
    in
    let version = Marshal.from_channel fin in
    if version <> asmRep_version then begin
      debug "asm: %s has old version\n" filename ;
      failwith "version mismatch"
    end ;
    range := Marshal.from_channel fin ;
    base := Marshal.from_channel fin ;
    super#load_binary ~in_channel:fin filename ;
    debug "asm: %s: loaded\n" filename ;
    if in_channel = None then close_in fin
  end

  method max_atom () = List.fold_left (+) 0 (List.map (fun (a,b) -> (b - a)) !range)

  method atom_id_of_source_line source_file source_line =
    (* return the in-code offset from the global offset *)
    List.fold_left (+) 0 (List.map (fun (a,b) ->
                                      if (a > source_line) then
                                        if (b > source_line) then
                                          (b - a)
                                        else
                                          (source_line - a)
                                      else
                                        0) !range)

  method source_line_of_atom_id atom_id = begin
    (* return global offset from in-code offset *)
    let j = ref 0 in
    let i = ref atom_id in
      List.iter (fun (b,e) ->
                   if (!j == 0) then begin
                     let chunk_size = (e - b) in
                       if (!i > chunk_size) then
                         i := !i - chunk_size
                       else
                         j := b + !i
                   end
                ) !range ;
      !j
  end

  method load_oracle oracle_file = 
	failwith "asm: no oracle fix localization"

  method structural_signature =
    failwith "asm: no structural differencing"

  method get_compiler_command () =
    "__COMPILER_NAME__ -o __EXE_NAME__ __SOURCE_NAME__ __COMPILER_OPTIONS__ "^
      "2>/dev/null >/dev/null"

  method mem_mapping asm_name bin_name =
    let lst = ref [] in
    let keep_by_regex reg_str lst =
      let it = ref [] in
      let regexp = Str.regexp reg_str in
        List.iter (fun line ->
                     if (Str.string_match regexp line 0) then
                       it := Str.matched_string line :: !it) lst ;
        (List.rev !it) in
    let read_file filename =
      let fin = open_in filename in
        (try while true do
           let line = input_line fin in
             lst := line :: !lst
         done with _ -> close_in fin) ;
        List.rev !lst in
    let asm_lines = read_file asm_name in
    let keep_by_regexp_ind reg_str indexes =
      let lst = List.map (fun i -> (i, List.nth asm_lines i)) indexes in
      let it = ref [] in
      let regexp = Str.regexp reg_str in
        List.iter (fun (i, line) ->
                     if (Str.string_match regexp line 0) then
                       it := i :: !it) lst ;
        (List.rev !it) in
    let gdb_disassemble func =
      let tmp = Filename.temp_file "cg" ".c" in
        ignore (Unix.system
                  ("gdb --batch --eval-command=\"disassemble "^func^"\" "^bin_name^">"^tmp)) ;
        read_file tmp in
    let addrs func =
      let regex = Str.regexp "[\\s]*0x([\\S]+)[\\s]*<([\\S]+)>:.*" in
      let it = ref [] in
        List.iter (fun line ->
                     if (Str.string_match regex line 0) then
                       it := (Str.matched_group 1 line) :: !it)
          (gdb_disassemble func) ;
        List.rev !it in
    let lines func =
      let on = ref false in
      let collector = ref [] in
      let regex = Str.regexp "^([^\\.][\\S]+):" in
        Array.iteri (fun i line ->
                       if !on then
                         collector := i :: !collector;
                       if (Str.string_match regex line 0) then
                         if ((String.compare func (Str.matched_string line)) == 0) then
                           on := true
                         else
                           on := false)
          (Array.of_list asm_lines) ;
        List.rev !collector in
      List.sort (fun (adr_a, ln_a) (adr_b, ln_b) -> adr_a - adr_b)
        (List.flatten
           (List.map
              (fun func ->
                 List.combine
                   (List.map (fun str -> int_of_string ("0x"^str)) (addrs func))
                   (keep_by_regexp_ind "^([^\\.\\s][\\S]+):" (lines func)))
              (keep_by_regex "^([^\\.\\s][\\S]+):" asm_lines)))

  method get_coverage coverage_sourcename coverage_exename coverage_outname =
    (* the use of two executable allows oprofile to sample the pos
     * and neg test executions separately.  *)
    let pos_exe = coverage_exename^".pos" in
      let neg_exe = coverage_exename^".neg" in
		ignore(Unix.system ("cp "^coverage_exename^" "^coverage_exename^".pos"));
		ignore(Unix.system ("cp "^coverage_exename^" "^coverage_exename^".neg"));
        for i = 1 to !asm_sample_runs do (* run the positive tests *)
          for i = 1 to !pos_tests do
            let res, _ = (self#internal_test_case pos_exe
                            coverage_sourcename (Positive i)) in
              if not res then begin
                debug "ERROR: coverage FAILS test Positive %d\n" i ;
              end ;
          done ;
          for i = 1 to !neg_tests do
            let res, _ = (self#internal_test_case neg_exe 
                            coverage_sourcename (Negative i)) in 
              if res then begin 
                (* debug "ERROR: coverage PASSES test Negative %d\n" i ; *)
              end ;
          done ;
        done ;
        (* collect the sampled results *)
        let grep = "|grep '^  *[0-9]'|sed 's/://g'|awk '{print $3\" \"$1}'|sort" in
        let join = "|awk '{print $3}'|sort -n" in
        let pos_samp = pos_exe^".samp" in
        let neg_samp = neg_exe^".samp" in
        let mapping  = self#mem_mapping coverage_sourcename coverage_exename in
        let map_path = (coverage_exename^".mapping") in
        let fout     = open_out map_path in
          (* write the mapping to a file *)
          List.iter (fun (addr, index) ->
                       Printf.fprintf fout "%d %d\n" addr index) mapping ;
          close_out fout ;
          (* collect the samples *)
          ignore (Unix.system ("opannotate -a "^pos_exe^grep^">"^pos_samp)) ;
          ignore (Unix.system ("opannotate -a "^neg_exe^grep^">"^neg_samp)) ;
          (* convert samples to LOC *)
          ignore (Unix.system ("join -i "^pos_samp^" "^map_path^join^">"^(!fix_path))) ;
          ignore (Unix.system ("join -i "^neg_samp^" "^map_path^join^">"^(!fault_path)))


  method instrument_fault_localization
    coverage_sourcename
    coverage_exename
    coverage_outname
    = begin
      debug "asmRep: computing fault localization information\n" ;
      debug "asmRep: ensure oprofile is running\n" ;
      debug "asmRep: this may take some time...\n" ;
      (* save the source to coverage_sourcename *)
      self#output_source coverage_sourcename ;
    end

  method debug_info () = begin
    debug "asm: lines = %d\n" (self#max_atom ());
  end

  method get ind =
    !base.(self#source_line_of_atom_id ind)
  method put ind newv =
    let idx = self#source_line_of_atom_id ind in
    super#put idx newv ;
    !base.(idx) <- newv

  method swap i_off j_off =
    let i = self#source_line_of_atom_id i_off in
    let j = self#source_line_of_atom_id j_off in
    super#swap i j ;
    let temp = !base.(i) in
    !base.(i) <- !base.(j) ;
    !base.(j) <- temp

  method delete i_off =
    let i = self#source_line_of_atom_id i_off in
    super#delete i ;
    !base.(i) <- []

  method append i_off j_off =
    let i = self#source_line_of_atom_id i_off in
    let j = self#source_line_of_atom_id j_off in
    super#append i j ;
    !base.(i) <- !base.(i) @ !base.(j)

end