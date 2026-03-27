*&---------------------------------------------------------------------*
*& Report ZMM_SLOW_MOVING_OOALV
*&---------------------------------------------------------------------*
REPORT zmm_slow_moving_ooalv_kf930.

DATA: lv_s_matnr TYPE mard-matnr, "避免使用tables: , 所以直接參考表欄位類型
      lv_s_werks TYPE mard-werks,
      lv_s_lgort TYPE mard-lgort.

SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE TEXT-001.
  PARAMETERS: p_days TYPE i DEFAULT 100 OBLIGATORY.
  SELECT-OPTIONS: s_matnr FOR lv_s_matnr,
                  s_werks FOR lv_s_werks OBLIGATORY,
                  s_lgort FOR lv_s_lgort.
SELECTION-SCREEN END OF BLOCK b1.

CLASS lcl_report DEFINITION FINAL.
  PUBLIC SECTION.
    TYPES: BEGIN OF ty_alv_line,
             light      TYPE icon-id,   "改為圖示類型
             matnr      TYPE matnr,     "料號
             maktx      TYPE maktx,     "料號敘述
             werks      TYPE werks_d,   "工廠
             lgort      TYPE lgort_d,   "倉庫
             labst      TYPE labst,     "估值非限制性庫存
             meins      TYPE meins,     "單位
             verpr      TYPE verpr,     "移動平均價格/週期單位價格
             waers      TYPE waers,     "貨幣碼(Currency Key) : USD
             peinh      TYPE peinh,     "價格的數量基準
             d_amt      TYPE dmbtr,     " 使用標準金額類型
             ersda      TYPE ersda,     "建立者
             last_in    TYPE budat,     "最後一筆入庫日期
             last_usage TYPE budat,     "最後一筆使用日期
             slow_days  TYPE i,
           END OF ty_alv_line,

   ty_alv_tab TYPE STANDARD TABLE OF ty_alv_line WITH EMPTY KEY. "這個內表不需要任何欄位來當作唯一識別或排序的依據

    METHODS: constructor,     "先定義有哪些方法, 跟C#的Interface有點類似
             main.

  PRIVATE SECTION.
    DATA: mt_alv      TYPE ty_alv_tab,
          mo_alv      TYPE REF TO cl_salv_table.

    METHODS: get_data,
             process_logic,
             build_and_display_alv,
             set_column_titles
               IMPORTING io_columns TYPE REF TO cl_salv_columns." 設置欄位標題
ENDCLASS.

CLASS lcl_report IMPLEMENTATION.

  METHOD constructor.
    IF s_werks[] IS INITIAL.
      MESSAGE '工廠必須輸入' TYPE 'E'.
    ENDIF.
  ENDMETHOD.

  METHOD main.
    get_data( ).
    process_logic( ).
    build_and_display_alv( ).
  ENDMETHOD.

  METHOD get_data.
    SELECT FROM mard AS m "MARD物料主檔-儲存位置資料
         INNER JOIN makt AS kt ON kt~matnr = m~matnr AND kt~spras = @sy-langu "MAKT物料敘述檔
         INNER JOIN mara AS ma ON ma~matnr = m~matnr  "MARA物料主檔-一般資料
         LEFT OUTER JOIN t001k AS tk ON tk~bwkey = m~werks  "T001K評估範圍, 取得物料的公司碼
         LEFT OUTER JOIN t001  AS t  ON t~bukrs  = tk~bukrs "T001公司碼檔, 取得幣別
           FIELDS
             m~matnr,
             kt~maktx,
             m~werks,
             m~lgort,
             m~labst,
             ma~meins,
             t~waers,
             m~ersda
           WHERE m~matnr IN @s_matnr
             AND m~werks IN @s_werks
             AND m~lgort IN @s_lgort
             AND m~labst > 0
           INTO CORRESPONDING FIELDS OF TABLE @mt_alv.

    IF mt_alv IS INITIAL.
      MESSAGE '未發現符合的資料' TYPE 'S' DISPLAY LIKE 'E'.
      RETURN.
    ENDIF.
  ENDMETHOD.

  METHOD process_logic.
    CHECK mt_alv IS NOT INITIAL.  "不合就跳出method

    SELECT matnr, bwkey, verpr, stprs, peinh, vprsv
      FROM mbew "放物料價錢
      FOR ALL ENTRIES IN @mt_alv
      WHERE matnr = @mt_alv-matnr AND bwkey = @mt_alv-werks
      INTO TABLE @DATA(lt_mbew).

    SELECT matnr, werks, lgort, bwart, shkzg, budat_mkpf AS budat
      FROM mseg "料件交易明細, 資料很大
      FOR ALL ENTRIES IN @mt_alv
      WHERE matnr = @mt_alv-matnr
        AND werks = @mt_alv-werks
        AND lgort = @mt_alv-lgort
      INTO TABLE @DATA(lt_mseg).

    LOOP AT mt_alv ASSIGNING FIELD-SYMBOL(<ls_alv>). "將<ls_alv>指向 mt_alv 的當前行
      READ TABLE lt_mbew INTO DATA(ls_mbew) "因為沒有要修改, 所以使用 INTO DATA(ls_mbew)
           WITH KEY matnr = <ls_alv>-matnr
                    bwkey = <ls_alv>-werks.
      IF sy-subrc = 0.
        DATA(lv_price) = COND #( WHEN ls_mbew-vprsv = 'S'
                                 THEN ls_mbew-stprs
                                 ELSE ls_mbew-verpr ).
        <ls_alv>-verpr = lv_price.
        <ls_alv>-peinh = ls_mbew-peinh.
        <ls_alv>-d_amt = COND #( WHEN ls_mbew-peinh <> 0
                                 THEN ( <ls_alv>-labst * lv_price ) / ls_mbew-peinh
                                 ELSE 0 ).
      ENDIF.

      LOOP AT lt_mseg ASSIGNING FIELD-SYMBOL(<ls_mseg>)
           WHERE matnr = <ls_alv>-matnr
             AND werks = <ls_alv>-werks
             AND lgort = <ls_alv>-lgort.
        IF ( <ls_mseg>-bwart = '201' OR <ls_mseg>-bwart = '221' OR
             <ls_mseg>-bwart = '261' OR <ls_mseg>-bwart = '543' OR
             <ls_mseg>-bwart = '601' ) AND <ls_mseg>-shkzg = 'H'.
          <ls_alv>-last_usage = COND #( WHEN <ls_mseg>-budat > <ls_alv>-last_usage "最後使用日期
                                        THEN <ls_mseg>-budat
                                        ELSE <ls_alv>-last_usage ).
        ELSEIF ( <ls_mseg>-bwart = '101' OR <ls_mseg>-bwart = '561' ) AND "採購收貨或是初始入庫
                 <ls_mseg>-shkzg = 'S'. "入庫
          <ls_alv>-last_in = COND #( WHEN <ls_mseg>-budat > <ls_alv>-last_in "最後入庫日期
                                     THEN <ls_mseg>-budat
                                     ELSE <ls_alv>-last_in ).
        ENDIF.
      ENDLOOP.

      DATA(lv_ref_date) = COND budat(
        WHEN <ls_alv>-last_usage IS NOT INITIAL THEN <ls_alv>-last_usage
        WHEN <ls_alv>-last_in    IS NOT INITIAL THEN <ls_alv>-last_in
        ELSE <ls_alv>-ersda ).
      <ls_alv>-slow_days = sy-datum - lv_ref_date.

      " 將狀態碼轉換為圖標
      <ls_alv>-light = COND #(
        WHEN <ls_alv>-slow_days >= 365 THEN icon_red_light      " '@5B@'
        WHEN <ls_alv>-slow_days >= 180 THEN icon_yellow_light   " '@5C@'
        ELSE icon_green_light ).                               " 綠燈
    ENDLOOP.

    IF p_days > 0.
      DELETE mt_alv WHERE slow_days < p_days.
    ENDIF.
    SORT mt_alv BY slow_days DESCENDING.
  ENDMETHOD.

  METHOD set_column_titles.
    " 設置所有欄位的中文標題
    DATA: lo_column TYPE REF TO cl_salv_column.

    TRY.
        lo_column = io_columns->get_column( 'LIGHT' ).
        lo_column->set_short_text( '狀態' ).
        lo_column->set_medium_text( '狀態' ).
        lo_column->set_long_text( '狀態' ).
      CATCH cx_salv_not_found.
    ENDTRY.

    TRY.
        lo_column = io_columns->get_column( 'MATNR' ).
        lo_column->set_short_text( '物料編號' ).
        lo_column->set_medium_text( '物料編號' ).
        lo_column->set_long_text( '物料編號' ).
      CATCH cx_salv_not_found.
    ENDTRY.

    TRY.
        lo_column = io_columns->get_column( 'MAKTX' ).
        lo_column->set_short_text( '物料描述' ).
        lo_column->set_medium_text( '物料描述' ).
        lo_column->set_long_text( '物料描述' ).
      CATCH cx_salv_not_found.
    ENDTRY.

    TRY.
        lo_column = io_columns->get_column( 'WERKS' ).
        lo_column->set_short_text( '工廠' ).
        lo_column->set_medium_text( '工廠' ).
        lo_column->set_long_text( '工廠' ).
      CATCH cx_salv_not_found.
    ENDTRY.

    TRY.
        lo_column = io_columns->get_column( 'LGORT' ).
        lo_column->set_short_text( '倉庫' ).
        lo_column->set_medium_text( '倉庫' ).
        lo_column->set_long_text( '倉庫' ).
      CATCH cx_salv_not_found.
    ENDTRY.

    TRY.
        lo_column = io_columns->get_column( 'LABST' ).
        lo_column->set_short_text( '庫存數量' ).
        lo_column->set_medium_text( '庫存數量' ).
        lo_column->set_long_text( '庫存數量' ).
      CATCH cx_salv_not_found.
    ENDTRY.

    TRY.
        lo_column = io_columns->get_column( 'MEINS' ).
        lo_column->set_short_text( '單位' ).
        lo_column->set_medium_text( '單位' ).
        lo_column->set_long_text( '單位' ).
      CATCH cx_salv_not_found.
    ENDTRY.

    TRY.
        lo_column = io_columns->get_column( 'VERPR' ).
        lo_column->set_short_text( '單價' ).
        lo_column->set_medium_text( '單價' ).
        lo_column->set_long_text( '單價' ).
      CATCH cx_salv_not_found.
    ENDTRY.

    TRY.
        lo_column = io_columns->get_column( 'WAERS' ).
        lo_column->set_short_text( '幣別' ).
        lo_column->set_medium_text( '幣別' ).
        lo_column->set_long_text( '幣別' ).
      CATCH cx_salv_not_found.
    ENDTRY.

    TRY.
        lo_column = io_columns->get_column( 'PEINH' ).
        lo_column->set_short_text( '價格單位' ).
        lo_column->set_medium_text( '價格單位' ).
        lo_column->set_long_text( '價格單位' ).
      CATCH cx_salv_not_found.
    ENDTRY.

    TRY.
        lo_column = io_columns->get_column( 'D_AMT' ).
        lo_column->set_short_text( '呆滯金額' ).
        lo_column->set_medium_text( '呆滯金額' ).
        lo_column->set_long_text( '呆滯金額' ).
      CATCH cx_salv_not_found.
    ENDTRY.

    TRY.
        lo_column = io_columns->get_column( 'ERSDA' ).
        lo_column->set_short_text( '創建日期' ).
        lo_column->set_medium_text( '創建日期' ).
        lo_column->set_long_text( '創建日期' ).
      CATCH cx_salv_not_found.
    ENDTRY.

    TRY.
        lo_column = io_columns->get_column( 'LAST_IN' ).
        lo_column->set_short_text( '最後入庫日' ).
        lo_column->set_medium_text( '最後入庫日' ).
        lo_column->set_long_text( '最後入庫日' ).
      CATCH cx_salv_not_found.
    ENDTRY.

    TRY.
        lo_column = io_columns->get_column( 'LAST_USAGE' ).
        lo_column->set_short_text( '最後領用日' ).
        lo_column->set_medium_text( '最後領用日' ).
        lo_column->set_long_text( '最後領用日' ).
      CATCH cx_salv_not_found.
    ENDTRY.

    TRY.
        lo_column = io_columns->get_column( 'SLOW_DAYS' ).
        lo_column->set_short_text( '呆滯天數' ).
        lo_column->set_medium_text( '呆滯天數' ).
        lo_column->set_long_text( '呆滯天數' ).
      CATCH cx_salv_not_found.
    ENDTRY.
  ENDMETHOD.

  METHOD build_and_display_alv.
    TRY.
        cl_salv_table=>factory(
          IMPORTING
            r_salv_table = mo_alv
          CHANGING
            t_table      = mt_alv ).

        DATA(lo_columns) = mo_alv->get_columns( ).
        lo_columns->set_optimize( abap_true ).

        " 設置所有欄位的中文標題
        set_column_titles( lo_columns ).

        " 設置排序
        DATA(lo_sorts) = mo_alv->get_sorts( ).
        lo_sorts->add_sort( columnname = 'SLOW_DAYS'
                            sequence   = if_salv_c_sort=>sort_down ).

        " 設置匯總（金額和數量）
        DATA(lo_aggregations) = mo_alv->get_aggregations( ).
        lo_aggregations->add_aggregation( columnname = 'D_AMT' ).
        lo_aggregations->add_aggregation( columnname = 'LABST' ).

        " 設置斑馬紋
        DATA(lo_display) = mo_alv->get_display_settings( ).
        lo_display->set_striped_pattern( abap_true ).

        "開啟所有標準功能的開關
        DATA(lo_functions) = mo_alv->get_functions( ).
        lo_functions->set_all( abap_true ).

        " 顯示 ALV
        mo_alv->display( ).

      CATCH cx_salv_msg INTO DATA(lx_error).
        MESSAGE lx_error TYPE 'E'.
    ENDTRY.
  ENDMETHOD.
ENDCLASS.

START-OF-SELECTION.
  DATA(lo_report) = NEW lcl_report( ).
  lo_report->main( ).