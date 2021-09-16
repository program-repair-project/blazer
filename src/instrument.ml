module DfSan = struct
  module NodeInfo = struct
    type t = Yojson.Safe.t

    let cmd_of t =
      ((t |> function
        | `Assoc l -> List.assoc "cmd" l
        | _ -> failwith "Invalid format")
       |> function
       | `List l -> List.hd l
       | _ -> failwith "Invalid format")
      |> function
      | `String s -> s
      | _ -> failwith "Invalid format"

    let filename_of t =
      t
      |> (function
           | `Assoc l -> List.assoc "loc" l | _ -> failwith "Invalid format")
      |> (function `String s -> s | _ -> failwith "Invalid format")
      |> String.split_on_char ':' |> Fun.flip List.nth 0
  end

  module NodeInfoMap = struct
    module M = Map.Make (String)

    type t = NodeInfo.t M.t

    let empty = M.empty

    let add = M.add

    let find = M.find
  end

  module LineSet = Set.Make (String)
  module FileToEdges = Map.Make (String)

  let read_nodes file =
    let ic = open_in file in
    Yojson.Safe.from_channel ic
    |> (function
         | `Assoc l -> List.assoc "nodes" l | _ -> failwith "Invalid format")
    |> (function `Assoc l -> l | _ -> failwith "Invalid format")
    |> List.fold_left
         (fun map (name, info) -> NodeInfoMap.add name info map)
         NodeInfoMap.empty
    |> fun x ->
    close_in ic;
    x

  let read_covered_lines file =
    let ic = open_in file in
    let rec loop lst =
      match input_line ic with
      | line -> (
          String.split_on_char '\t' line |> function
          | h :: _ -> loop (LineSet.add h lst)
          | _ -> failwith "Invalid format")
      | exception End_of_file -> lst
    in
    loop LineSet.empty |> fun x ->
    close_in ic;
    x

  let read_duedges nodes file =
    let ic = open_in file in
    let rec loop map =
      match input_line ic with
      | line -> (
          String.split_on_char '\t' line |> function
          | src :: dst :: _ ->
              let file = NodeInfoMap.find src nodes |> NodeInfo.filename_of in
              FileToEdges.update file
                (function
                  | None -> Some [ (src, dst) ]
                  | Some l -> Some ((src, dst) :: l))
                map
              |> loop
          | _ -> failwith "Invalid format")
      | exception End_of_file -> map
    in
    loop FileToEdges.empty |> fun x ->
    close_in ic;
    x

  type dfsan_funs = {
    create_label : Cil.varinfo;
    set_label : Cil.varinfo;
    get_label : Cil.varinfo;
    has_label : Cil.varinfo;
  }

  let initialize work_dir =
    let result_file = Filename.concat work_dir "localizer-out/result.txt" in
    let sparrow_out_dir = Filename.concat work_dir "sparrow-out" in
    let node_file = Filename.concat sparrow_out_dir "node.json" in
    let duedge_file =
      Filename.concat sparrow_out_dir "interval/datalog/DUEdge.facts"
    in
    let nodes = read_nodes node_file in
    let lines = read_covered_lines result_file in
    let duedges = read_duedges nodes duedge_file in
    (nodes, lines, duedges)

  let rec instrument_instr dfsan_funs edges instrs results =
    match instrs with
    | (Cil.Set ((Var vi, NoOffset), _, loc) as i) :: tl ->
        let name = Cil.mkString vi.vname in
        Cil.Call
          ( None,
            Cil.Lval (Cil.Var dfsan_funs.create_label, Cil.NoOffset),
            [ name; Cil.zero ],
            loc )
        :: i :: results
        |> instrument_instr dfsan_funs edges tl
    | i :: tl -> i :: results |> instrument_instr dfsan_funs edges tl
    | [] -> List.rev results

  class assignVisitor dfsan_funs edges =
    object
      inherit Cil.nopCilVisitor

      method! vstmt s =
        match s.Cil.skind with
        | Cil.Instr i ->
            s.Cil.skind <- Cil.Instr (instrument_instr dfsan_funs edges i []);
            DoChildren
        | _ -> DoChildren
    end

  let instrument file pp_file _ edges =
    Logging.log "Instrument %s (%s)" file pp_file;
    let cil = Frontc.parse pp_file () in
    let dfsan_funs =
      {
        create_label =
          Cil.findOrCreateFunc cil "dfsan_create_label"
            (Cil.TFun (Cil.voidType, None, false, []));
        set_label =
          Cil.findOrCreateFunc cil "dfsan_set_label"
            (Cil.TFun (Cil.voidType, None, false, []));
        get_label =
          Cil.findOrCreateFunc cil "dfsan_get_label"
            (Cil.TFun (Cil.voidType, None, false, []));
        has_label =
          Cil.findOrCreateFunc cil "dfsan_has_label"
            (Cil.TFun (Cil.voidType, None, false, []));
      }
    in
    Cil.visitCilFile (new assignVisitor dfsan_funs edges) cil;
    let oc = open_out pp_file in
    Cil.dumpFile !Cil.printerForMaincil oc "" cil;
    close_out oc

  let run work_dir src_dir =
    let nodes, _, duedges = initialize work_dir in
    FileToEdges.iter
      (fun file edges ->
        if file = "" then ()
        else
          let name = Filename.remove_extension file in
          let pp_file = Filename.concat src_dir (name ^ ".i") in
          if Sys.file_exists pp_file then instrument file pp_file nodes edges
          else Logging.log "%s not found" file)
      duedges
end

module GSA = struct
  let pred_num = ref (-1)

  let new_pred () =
    pred_num := !pred_num + 1;
    "OOJAHOOO_PRED_" ^ string_of_int !pred_num

  class assignInitializer f =
    let add_predicate_var result stmt =
      match stmt.Cil.skind with
      | Cil.If (pred, then_branch, else_branch, loc) ->
          let pred_var = new_pred () in
          let vi = Cil.makeLocalVar f pred_var (Cil.TInt (Cil.IInt, [])) in
          stmt.Cil.skind <-
            Cil.If
              ( Cil.Lval (Cil.Var vi, Cil.NoOffset),
                then_branch,
                else_branch,
                loc );
          result
          @ [
              Cil.mkStmtOneInstr
                (Cil.Set ((Cil.Var vi, Cil.NoOffset), pred, loc));
              stmt;
            ]
      | _ -> result @ [ stmt ]
    in
    object
      inherit Cil.nopCilVisitor

      method! vblock b =
        let new_stmts = List.fold_left add_predicate_var [] b.Cil.bstmts in
        b.bstmts <- new_stmts;
        DoChildren
    end

  class predicateVisitor =
    object
      inherit Cil.nopCilVisitor

      method! vfunc f =
        if
          String.length f.svar.vname >= 6
          && (String.equal (String.sub f.svar.vname 0 6) "bugzoo"
             || String.equal (String.sub f.svar.vname 0 6) "unival")
        then SkipChildren
        else ChangeTo (Cil.visitCilFunction (new assignInitializer f) f)
    end

  let predicate_transform pp_file =
    let origin_file = Filename.remove_extension pp_file ^ ".c" in
    Logging.log "Predicate transform %s (%s)" origin_file pp_file;
    let cil_opt =
      try Some (Frontc.parse pp_file ()) with Frontc.ParseError _ -> None
    in
    if Option.is_none cil_opt then pp_file
    else
      let cil = Option.get cil_opt in
      Cil.visitCilFile (new predicateVisitor) cil;
      let oc = open_out pp_file in
      Cil.dumpFile !Cil.printerForMaincil oc "" cil;
      close_out oc;
      pp_file

  module CausalMap = Map.Make (String)
  module VarSet = Set.Make (String)
  module VarVerMap = Map.Make (String)
  module VarMap = Map.Make (String)

  let causal_map = ref CausalMap.empty

  let var_ver = ref VarVerMap.empty

  class assignVisitor record_func f =
    let vname_of lv =
      match lv with Cil.Var vi, Cil.NoOffset -> vi.Cil.vname | _ -> ""
    in
    let varinfo_of lv =
      match lv with
      | Cil.Var vi, Cil.NoOffset -> vi
      | _ -> Cil.makeVarinfo false "" (Cil.TVoid [])
    in
    let rec var_names_of exp =
      let result =
        match exp with
        | Cil.Lval lv -> VarMap.singleton (vname_of lv) (varinfo_of lv)
        | Cil.SizeOfE e -> var_names_of e
        | Cil.AlignOfE e -> var_names_of e
        | Cil.UnOp (_, e, _) -> var_names_of e
        | Cil.BinOp (_, e1, e2, _) ->
            VarMap.union
              (fun _ va1 _ -> Some va1)
              (var_names_of e1) (var_names_of e2)
        | Cil.Question (e1, e2, e3, _) ->
            VarMap.union
              (fun _ va1 _ -> Some va1)
              (VarMap.union
                 (fun _ va1 _ -> Some va1)
                 (var_names_of e1) (var_names_of e2))
              (var_names_of e3)
        | Cil.CastE (_, e) -> var_names_of e
        | _ -> VarMap.empty
      in
      VarMap.remove "" result
    in
    let is_pred vname =
      let pred_prefix = Str.regexp "OOJAHOOO_PRED_\[0-9\]\+" in
      Str.string_match pred_prefix vname 0
    in
    let rec string_of_typ = function
      | Cil.TInt (Cil.IChar, _) -> "char"
      | Cil.TInt (Cil.ISChar, _) -> "signed char"
      | Cil.TInt (Cil.IUChar, _) -> "unsigned char"
      | Cil.TInt (Cil.IInt, _) -> "int"
      | Cil.TInt (Cil.IUInt, _) -> "unsigned int"
      | Cil.TInt (Cil.IShort, _) -> "short"
      | Cil.TInt (Cil.IUShort, _) -> "unsigned short"
      | Cil.TInt (Cil.ILong, _) -> "long"
      | Cil.TInt (Cil.IULong, _) -> "unsigned long"
      | Cil.TFloat (Cil.FFloat, _) -> "float"
      | Cil.TFloat (Cil.FDouble, _) -> "double"
      | Cil.TFloat (Cil.FLongDouble, _) -> "long double"
      | Cil.TPtr (Cil.TInt (Cil.IChar, _), _) -> "string"
      | Cil.TNamed (t, _) -> string_of_typ t.ttype
      | _ -> "NA"
    in
    let call_record var vname ver loc =
      let fun_name = f.Cil.svar.vname in
      let t = string_of_typ (Cil.typeOfLval var) in
      match t with
      | "NA" ->
          Cil.Call
            ( None,
              Cil.Lval (Cil.Var record_func, Cil.NoOffset),
              [
                Cil.Const (CStr loc.Cil.file);
                Cil.Const (Cil.CStr fun_name);
                Cil.Const
                  (Cil.CInt64 (Int64.of_int loc.Cil.line, Cil.IInt, None));
                Cil.Const (Cil.CStr vname);
                Cil.Const (Cil.CInt64 (Int64.of_int ver, Cil.IInt, None));
                Cil.Const (Cil.CStr t);
              ],
              loc )
      | _ ->
          Cil.Call
            ( None,
              Cil.Lval (Cil.Var record_func, Cil.NoOffset),
              [
                Cil.Const (CStr loc.Cil.file);
                Cil.Const (Cil.CStr fun_name);
                Cil.Const
                  (Cil.CInt64 (Int64.of_int loc.Cil.line, Cil.IInt, None));
                Cil.Const (Cil.CStr vname);
                Cil.Const (Cil.CInt64 (Int64.of_int ver, Cil.IInt, None));
                Cil.Const (Cil.CStr t);
                Cil.Lval var;
              ],
              loc )
    in
    let ass2gsa result instr =
      let gogo, lv, lval, exp_vars, loc =
        match instr with
        | Cil.Set (lv, exp, loc) ->
            let exp_vars = var_names_of exp in
            let lval = vname_of lv in
            (true, lv, lval, exp_vars, loc)
        | Call (lv_opt, _, params, loc) ->
            if Option.is_none lv_opt then
              ( false,
                (Var (Cil.makeVarinfo false "" (Cil.TVoid [])), Cil.NoOffset),
                "",
                VarMap.empty,
                loc )
            else
              let lv = Option.get lv_opt in
              let exp_vars =
                List.fold_left
                  (fun ev param ->
                    VarMap.union
                      (fun _ vi1 _ -> Some vi1)
                      ev (var_names_of param))
                  VarMap.empty params
              in
              let lval = vname_of lv in
              (true, lv, lval, exp_vars, loc)
        | _ ->
            ( false,
              (Var (Cil.makeVarinfo false "" (Cil.TVoid [])), Cil.NoOffset),
              "",
              VarMap.empty,
              { line = -1; file = ""; byte = -1 } )
      in
      if (not gogo) || lval = "" then result @ [ instr ]
      else if is_pred lval then (
        let exp_vars_with_ver, exp_vars_with_new_ver =
          VarMap.fold
            (fun ev _ (vs, nvs) ->
              (* for debugging *)
              (* print_endline "a"; *)
              let ver = VarVerMap.find ev !var_ver in
              ( (ev ^ "_" ^ string_of_int ver) :: vs,
                (ev ^ "_" ^ string_of_int (ver + 1)) :: nvs ))
            exp_vars ([], [])
        in
        causal_map := CausalMap.add lval exp_vars_with_ver !causal_map;
        let new_var_ver =
          VarVerMap.mapi
            (fun v ver -> if VarMap.mem v exp_vars then ver + 1 else ver)
            !var_ver
        in
        List.iter2
          (fun old_ver new_ver ->
            causal_map := CausalMap.add new_ver [ old_ver ] !causal_map)
          exp_vars_with_ver exp_vars_with_new_ver;
        let pred_record = call_record lv lval 0 loc in
        let records =
          VarMap.fold
            (fun vname vi rs ->
              (* for debugging *)
              (* print_endline "b"; *)
              call_record (Cil.Var vi, Cil.NoOffset) vname
                (VarMap.find vname new_var_ver)
                loc
              :: rs)
            exp_vars []
        in
        var_ver := new_var_ver;
        result @ instr :: pred_record :: records)
      else
        let new_var_ver =
          if VarVerMap.mem lval !var_ver then
            VarVerMap.update lval
              (fun ver -> Some (Option.get ver + 1))
              !var_ver
          else VarVerMap.add lval 0 !var_ver
        in
        let exp_vars_with_ver =
          VarMap.fold
            (fun ev _ vs ->
              (* for debugging *)
              (* print_endline ev; *)
              let ver = VarVerMap.find ev !var_ver in
              (ev ^ "_" ^ string_of_int ver) :: vs)
            exp_vars []
        in
        (* for debugging *)
        (* print_endline "d"; *)
        let ver_of_lval = VarVerMap.find lval new_var_ver in
        let lval_with_ver = lval ^ "_" ^ string_of_int ver_of_lval in
        causal_map := CausalMap.add lval_with_ver exp_vars_with_ver !causal_map;
        let lv_record = call_record lv lval ver_of_lval loc in
        var_ver := new_var_ver;
        result @ [ instr; lv_record ]
    in
    object
      inherit Cil.nopCilVisitor

      method! vstmt s =
        match s.Cil.skind with
        | Instr is ->
            s.Cil.skind <- Instr (List.fold_left ass2gsa [] is);
            DoChildren
        | _ -> DoChildren
    end

  class funAssignVisitor record_func origin_var_ver =
    object
      inherit Cil.nopCilVisitor

      method! vfunc f =
        if
          String.length f.svar.vname >= 6
          && (String.equal (String.sub f.svar.vname 0 6) "bugzoo"
             || String.equal (String.sub f.svar.vname 0 6) "unival")
        then Cil.SkipChildren
        else (
          var_ver := origin_var_ver;
          List.iter
            (fun form -> var_ver := VarVerMap.add form.Cil.vname 0 !var_ver)
            f.Cil.sformals;
          List.iter
            (fun form -> var_ver := VarVerMap.add form.Cil.vname 0 !var_ver)
            f.Cil.slocals;
          ChangeTo (Cil.visitCilFunction (new assignVisitor record_func f) f))
    end

  let extract_gvar globals =
    List.filter_map
      (fun g ->
        match g with
        | Cil.GVarDecl (vi, _) | Cil.GVar (vi, _, _) -> Some vi.Cil.vname
        | _ -> None)
      globals

  let gsa_gen pt_file =
    let ext_removed_file = Filename.remove_extension pt_file in
    let origin_file = ext_removed_file ^ ".c" in
    Logging.log "GSA_Gen %s (%s)" origin_file pt_file;
    let cil_opt =
      try Some (Frontc.parse pt_file ()) with Frontc.ParseError _ -> None
    in
    if Option.is_none cil_opt then ()
    else
      let cil = Option.get cil_opt in
      let global_vars = extract_gvar cil.Cil.globals in
      var_ver :=
        List.fold_left
          (fun vv gv -> VarVerMap.add gv 0 vv)
          VarVerMap.empty global_vars;
      let record_func =
        Cil.findOrCreateFunc cil
          ("unival_record_"
          ^ Utils.dash2under_bar (Filename.basename ext_removed_file))
          (Cil.TFun (Cil.intType, None, true, []))
      in
      Cil.visitCilFile (new funAssignVisitor record_func !var_ver) cil;
      let oc_dotc = open_out (ext_removed_file ^ ".c") in
      Cil.dumpFile !Cil.printerForMaincil oc_dotc "" cil;
      close_out oc_dotc

  let print_cm work_dir causal_map =
    let output_file = Filename.concat work_dir "CausalMap.txt" in
    let oc = open_out output_file in
    let cm_str =
      Utils.join
        (CausalMap.fold
           (fun var parents res -> Utils.join (var :: parents) "," :: res)
           causal_map [])
        "\n"
    in
    Printf.fprintf oc "%s" cm_str;
    close_out oc

  let run work_dir src_dir =
    Utils.traverse_pp_file
      (fun pp_file -> pp_file |> predicate_transform |> gsa_gen)
      src_dir;
    Utils.remove_temp_files src_dir;
    print_cm work_dir !causal_map
end

module Coverage = struct
  let location_of_instr = function
    | Cil.Set (_, _, l) | Cil.Call (_, _, _, l) | Cil.Asm (_, _, _, _, _, l) ->
        l

  let printf_of printf stream loc =
    Cil.Call
      ( None,
        Cil.Lval (Cil.Var printf, Cil.NoOffset),
        [
          Cil.Lval (Cil.Var stream, Cil.NoOffset);
          Cil.Const (Cil.CStr "%s:%d\n");
          Cil.Const (Cil.CStr loc.Cil.file);
          Cil.integer loc.Cil.line;
        ],
        loc )

  let flush_of flush stream loc =
    Cil.Call
      ( None,
        Cil.Lval (Cil.Var flush, Cil.NoOffset),
        [ Cil.Lval (Cil.Var stream, Cil.NoOffset) ],
        loc )

  let found_type = ref None

  let found_gvar = ref None

  class findTypeVisitor name =
    object
      inherit Cil.nopCilVisitor

      method! vglob g =
        match g with
        | GCompTag (ci, _) ->
            if ci.Cil.cname = name then found_type := Some ci;
            SkipChildren
        | _ -> SkipChildren
    end

  class findGVarVisitor name =
    object
      inherit Cil.nopCilVisitor

      method! vglob g =
        match g with
        | GVarDecl (vi, _) ->
            if vi.Cil.vname = name then found_gvar := Some vi;
            SkipChildren
        | _ -> SkipChildren
    end

  class instrumentVisitor printf flush stream =
    object
      inherit Cil.nopCilVisitor

      method! vfunc fd =
        if fd.Cil.svar.vname = "bugzoo_ctor" then SkipChildren else DoChildren

      method! vblock blk =
        let bstmts =
          List.fold_left
            (fun bstmts s ->
              match s.Cil.skind with
              | Cil.Instr insts ->
                  let new_insts =
                    List.fold_left
                      (fun is i ->
                        let loc = Cil.get_instrLoc i in
                        let call = printf_of printf stream loc in
                        let flush = flush_of flush stream loc in
                        i :: flush :: call :: is)
                      [] insts
                    |> List.rev
                  in
                  s.skind <- Cil.Instr new_insts;
                  s :: bstmts
              | _ ->
                  let loc = Cil.get_stmtLoc s.Cil.skind in
                  let call =
                    printf_of printf stream loc |> Cil.mkStmtOneInstr
                  in
                  let flush = flush_of flush stream loc |> Cil.mkStmtOneInstr in
                  s :: flush :: call :: bstmts)
            [] blk.Cil.bstmts
          |> List.rev
        in
        blk.bstmts <- bstmts;
        Cil.DoChildren
    end

  let preamble src_dir =
    String.concat ""
      [
        "/* COVERAGE :: INSTRUMENTATION :: START */\n";
        "typedef struct _IO_FILE FILE;";
        "struct _IO_FILE *__cov_stream ;";
        "extern FILE *fopen(char const   * __restrict  __filename , char \
         const   * __restrict  __modes ) ;";
        "extern int fclose(FILE *__stream ) ;";
        "static void coverage_ctor (void) __attribute__ ((constructor(101)));\n";
        "static void coverage_ctor (void) {\n";
        "  __cov_stream = fopen(\"" ^ src_dir ^ "/coverage.txt\", \"a\");\n";
        "  fprintf(__cov_stream, \"__START_NEW_EXECUTION__\\n\");\n";
        "  fflush(__cov_stream);\n";
        "}\n";
        "static void coverage_dtor (void) __attribute__ ((destructor(101)));\n";
        "static void coverage_dtor (void) {\n";
        "  fclose(__cov_stream);\n";
        "}\n";
        "/* COVERAGE :: INSTRUMENTATION :: END */\n";
      ]

  let append_constructor work_dir filename =
    let read_whole_file filename =
      let ch = open_in filename in
      let s = really_input_string ch (in_channel_length ch) in
      close_in ch;
      s
    in
    let instr_c_code = preamble work_dir ^ read_whole_file filename in
    let oc = open_out filename in
    Printf.fprintf oc "%s" instr_c_code;
    close_out oc

  let instrument work_dir pt_file =
    let origin_file_paths =
      Utils.find_file (Filename.remove_extension pt_file ^ ".c") work_dir
    in
    let ori_file_num = List.length origin_file_paths in
    if ori_file_num = 0 then ()
    else
      let origin_file = List.hd origin_file_paths in
      Logging.log "Instrument Coverage %s (%s)" origin_file pt_file;
      let cil_opt =
        try Some (Frontc.parse pt_file ()) with Frontc.ParseError _ -> None
      in
      if Option.is_none cil_opt then ()
      else
        let cil = Option.get cil_opt in
        (* TODO: clean up *)
        Cil.visitCilFile (new findTypeVisitor "_IO_FILE") cil;
        Cil.visitCilFile (new findGVarVisitor "stderr") cil;
        if Option.is_none !found_type || Option.is_none !found_gvar then ()
        else
          let fileptr = Cil.TPtr (Cil.TComp (Option.get !found_type, []), []) in
          let printf =
            Cil.findOrCreateFunc cil "fprintf"
              (Cil.TFun
                 ( Cil.voidType,
                   Some
                     [
                       ("stream", fileptr, []); ("format", Cil.charPtrType, []);
                     ],
                   true,
                   [] ))
          in
          let flush =
            Cil.findOrCreateFunc cil "fflush"
              (Cil.TFun
                 (Cil.voidType, Some [ ("stream", fileptr, []) ], false, []))
          in
          let stream = Cil.makeGlobalVar "__cov_stream" fileptr in
          cil.globals <- Cil.GVarDecl (stream, Cil.locUnknown) :: cil.globals;
          Cil.visitCilFile (new instrumentVisitor printf flush stream) cil;
          Unix.system
            ("cp " ^ origin_file ^ " "
            ^ Filename.remove_extension pt_file
            ^ ".origin.c")
          |> ignore;
          (if
           List.mem (Filename.basename origin_file) [ "proc_open.c"; "cast.c" ]
          then ()
          else
            let oc = open_out origin_file in
            Cil.dumpFile !Cil.printerForMaincil oc "" cil;
            close_out oc);
          if
            List.mem
              (Filename.basename origin_file)
              [ "gzip.c"; "tif_unix.c"; "http_auth.c"; "main.c" ]
          then append_constructor work_dir origin_file

  let run work_dir src_dir =
    Utils.traverse_pp_file (instrument work_dir) src_dir
end

let run work_dir =
  Cil.initCIL ();
  let src_dir = Filename.concat work_dir "src" in
  match !Cmdline.instrument with
  | Cmdline.DfSan -> DfSan.run work_dir src_dir
  | Cmdline.GSA -> GSA.run work_dir src_dir
  | Cmdline.Coverage -> Coverage.run work_dir src_dir
  | Cmdline.Nothing -> ()
