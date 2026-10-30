// ============================================================================
// hud_rom_sincos.v
// 1024 点 sin/cos 查表 ROM，Q1.11；低 12bit=sin，高 12bit=cos，单口同步读
// 本文件由 tools/gen_hud_assets.py 自动生成，请勿手工修改！
// ============================================================================

module hud_rom_sincos(
    input  wire        clk,
    input  wire [9:0]  addr,     // 角度索引 0..1023  => 0..360 度
    output reg  [11:0] o_sin,
    output reg  [11:0] o_cos
);
    reg [23:0] mem [0:1023];

    // 若综合器不认 initial 初始化 BSRAM，把下面整段换成：
    //   initial $readmemh("hud_rom_sincos.mem", mem);
    initial begin
        mem[0]=24'h7FF000; mem[1]=24'h7FF00D; mem[2]=24'h7FF019; mem[3]=24'h7FF026; mem[4]=24'h7FE032; mem[5]=24'h7FE03F; mem[6]=24'h7FE04B; mem[7]=24'h7FD058;
        mem[8]=24'h7FD064; mem[9]=24'h7FC071; mem[10]=24'h7FB07E; mem[11]=24'h7FA08A; mem[12]=24'h7F9097; mem[13]=24'h7F80A3; mem[14]=24'h7F70B0; mem[15]=24'h7F60BC;
        mem[16]=24'h7F50C9; mem[17]=24'h7F40D5; mem[18]=24'h7F30E2; mem[19]=24'h7F10EE; mem[20]=24'h7F00FB; mem[21]=24'h7EE107; mem[22]=24'h7EC113; mem[23]=24'h7EB120;
        mem[24]=24'h7E912C; mem[25]=24'h7E7139; mem[26]=24'h7E5145; mem[27]=24'h7E3152; mem[28]=24'h7E115E; mem[29]=24'h7DF16A; mem[30]=24'h7DC177; mem[31]=24'h7DA183;
        mem[32]=24'h7D818F; mem[33]=24'h7D519C; mem[34]=24'h7D31A8; mem[35]=24'h7D01B4; mem[36]=24'h7CD1C1; mem[37]=24'h7CA1CD; mem[38]=24'h7C81D9; mem[39]=24'h7C51E5;
        mem[40]=24'h7C21F1; mem[41]=24'h7BF1FE; mem[42]=24'h7BB20A; mem[43]=24'h7B8216; mem[44]=24'h7B5222; mem[45]=24'h7B122E; mem[46]=24'h7AE23A; mem[47]=24'h7AA246;
        mem[48]=24'h7A7252; mem[49]=24'h7A325E; mem[50]=24'h79F26A; mem[51]=24'h79C276; mem[52]=24'h798282; mem[53]=24'h79428E; mem[54]=24'h79029A; mem[55]=24'h78C2A6;
        mem[56]=24'h7872B2; mem[57]=24'h7832BD; mem[58]=24'h77F2C9; mem[59]=24'h77A2D5; mem[60]=24'h7762E1; mem[61]=24'h7712EC; mem[62]=24'h76D2F8; mem[63]=24'h768304;
        mem[64]=24'h76330F; mem[65]=24'h75E31B; mem[66]=24'h759327; mem[67]=24'h754332; mem[68]=24'h74F33E; mem[69]=24'h74A349; mem[70]=24'h745354; mem[71]=24'h740360;
        mem[72]=24'h73A36B; mem[73]=24'h735377; mem[74]=24'h730382; mem[75]=24'h72A38D; mem[76]=24'h724398; mem[77]=24'h71F3A4; mem[78]=24'h7193AF; mem[79]=24'h7133BA;
        mem[80]=24'h70D3C5; mem[81]=24'h7073D0; mem[82]=24'h7013DB; mem[83]=24'h6FB3E6; mem[84]=24'h6F53F1; mem[85]=24'h6EF3FC; mem[86]=24'h6E9407; mem[87]=24'h6E2412;
        mem[88]=24'h6DC41C; mem[89]=24'h6D5427; mem[90]=24'h6CF432; mem[91]=24'h6C843D; mem[92]=24'h6C1447; mem[93]=24'h6BB452; mem[94]=24'h6B445C; mem[95]=24'h6AD467;
        mem[96]=24'h6A6471; mem[97]=24'h69F47C; mem[98]=24'h698486; mem[99]=24'h691490; mem[100]=24'h68A49B; mem[101]=24'h6824A5; mem[102]=24'h67B4AF; mem[103]=24'h6744B9;
        mem[104]=24'h66C4C3; mem[105]=24'h6654CD; mem[106]=24'h65D4D7; mem[107]=24'h6554E1; mem[108]=24'h64E4EB; mem[109]=24'h6464F5; mem[110]=24'h63E4FF; mem[111]=24'h636509;
        mem[112]=24'h62E513; mem[113]=24'h62651C; mem[114]=24'h61E526; mem[115]=24'h616530; mem[116]=24'h60E539; mem[117]=24'h606543; mem[118]=24'h5FD54C; mem[119]=24'h5F5555;
        mem[120]=24'h5ED55F; mem[121]=24'h5E4568; mem[122]=24'h5DC571; mem[123]=24'h5D357A; mem[124]=24'h5CB583; mem[125]=24'h5C258D; mem[126]=24'h5B9596; mem[127]=24'h5B059F;
        mem[128]=24'h5A75A7; mem[129]=24'h59F5B0; mem[130]=24'h5965B9; mem[131]=24'h58D5C2; mem[132]=24'h5835CB; mem[133]=24'h57A5D3; mem[134]=24'h5715DC; mem[135]=24'h5685E4;
        mem[136]=24'h55F5ED; mem[137]=24'h5555F5; mem[138]=24'h54C5FD; mem[139]=24'h543606; mem[140]=24'h53960E; mem[141]=24'h530616; mem[142]=24'h52661E; mem[143]=24'h51C626;
        mem[144]=24'h51362E; mem[145]=24'h509636; mem[146]=24'h4FF63E; mem[147]=24'h4F5646; mem[148]=24'h4EB64E; mem[149]=24'h4E1655; mem[150]=24'h4D765D; mem[151]=24'h4CD665;
        mem[152]=24'h4C366C; mem[153]=24'h4B9674; mem[154]=24'h4AF67B; mem[155]=24'h4A5682; mem[156]=24'h49B68A; mem[157]=24'h490691; mem[158]=24'h486698; mem[159]=24'h47C69F;
        mem[160]=24'h4716A6; mem[161]=24'h4676AD; mem[162]=24'h45C6B4; mem[163]=24'h4526BB; mem[164]=24'h4476C1; mem[165]=24'h43D6C8; mem[166]=24'h4326CF; mem[167]=24'h4276D5;
        mem[168]=24'h41C6DC; mem[169]=24'h4126E2; mem[170]=24'h4076E9; mem[171]=24'h3FC6EF; mem[172]=24'h3F16F5; mem[173]=24'h3E66FB; mem[174]=24'h3DB701; mem[175]=24'h3D0707;
        mem[176]=24'h3C570D; mem[177]=24'h3BA713; mem[178]=24'h3AF719; mem[179]=24'h3A471F; mem[180]=24'h398724; mem[181]=24'h38D72A; mem[182]=24'h382730; mem[183]=24'h377735;
        mem[184]=24'h36B73A; mem[185]=24'h360740; mem[186]=24'h354745; mem[187]=24'h34974A; mem[188]=24'h33E74F; mem[189]=24'h332754; mem[190]=24'h327759; mem[191]=24'h31B75E;
        mem[192]=24'h30F763; mem[193]=24'h304768; mem[194]=24'h2F876D; mem[195]=24'h2EC771; mem[196]=24'h2E1776; mem[197]=24'h2D577A; mem[198]=24'h2C977F; mem[199]=24'h2BD783;
        mem[200]=24'h2B2787; mem[201]=24'h2A678C; mem[202]=24'h29A790; mem[203]=24'h28E794; mem[204]=24'h282798; mem[205]=24'h27679C; mem[206]=24'h26A79F; mem[207]=24'h25E7A3;
        mem[208]=24'h2527A7; mem[209]=24'h2467AA; mem[210]=24'h23A7AE; mem[211]=24'h22E7B1; mem[212]=24'h2227B5; mem[213]=24'h2167B8; mem[214]=24'h20A7BB; mem[215]=24'h1FE7BF;
        mem[216]=24'h1F17C2; mem[217]=24'h1E57C5; mem[218]=24'h1D97C8; mem[219]=24'h1CD7CA; mem[220]=24'h1C17CD; mem[221]=24'h1B47D0; mem[222]=24'h1A87D3; mem[223]=24'h19C7D5;
        mem[224]=24'h18F7D8; mem[225]=24'h1837DA; mem[226]=24'h1777DC; mem[227]=24'h16A7DF; mem[228]=24'h15E7E1; mem[229]=24'h1527E3; mem[230]=24'h1457E5; mem[231]=24'h1397E7;
        mem[232]=24'h12C7E9; mem[233]=24'h1207EB; mem[234]=24'h1137EC; mem[235]=24'h1077EE; mem[236]=24'h0FB7F0; mem[237]=24'h0EE7F1; mem[238]=24'h0E27F3; mem[239]=24'h0D57F4;
        mem[240]=24'h0C97F5; mem[241]=24'h0BC7F6; mem[242]=24'h0B07F7; mem[243]=24'h0A37F8; mem[244]=24'h0977F9; mem[245]=24'h08A7FA; mem[246]=24'h07E7FB; mem[247]=24'h0717FC;
        mem[248]=24'h0647FD; mem[249]=24'h0587FD; mem[250]=24'h04B7FE; mem[251]=24'h03F7FE; mem[252]=24'h0327FE; mem[253]=24'h0267FF; mem[254]=24'h0197FF; mem[255]=24'h00D7FF;
        mem[256]=24'h0007FF; mem[257]=24'hFF37FF; mem[258]=24'hFE77FF; mem[259]=24'hFDA7FF; mem[260]=24'hFCE7FE; mem[261]=24'hFC17FE; mem[262]=24'hFB57FE; mem[263]=24'hFA87FD;
        mem[264]=24'hF9C7FD; mem[265]=24'hF8F7FC; mem[266]=24'hF827FB; mem[267]=24'hF767FA; mem[268]=24'hF697F9; mem[269]=24'hF5D7F8; mem[270]=24'hF507F7; mem[271]=24'hF447F6;
        mem[272]=24'hF377F5; mem[273]=24'hF2B7F4; mem[274]=24'hF1E7F3; mem[275]=24'hF127F1; mem[276]=24'hF057F0; mem[277]=24'hEF97EE; mem[278]=24'hEED7EC; mem[279]=24'hEE07EB;
        mem[280]=24'hED47E9; mem[281]=24'hEC77E7; mem[282]=24'hEBB7E5; mem[283]=24'hEAE7E3; mem[284]=24'hEA27E1; mem[285]=24'hE967DF; mem[286]=24'hE897DC; mem[287]=24'hE7D7DA;
        mem[288]=24'hE717D8; mem[289]=24'hE647D5; mem[290]=24'hE587D3; mem[291]=24'hE4C7D0; mem[292]=24'hE3F7CD; mem[293]=24'hE337CA; mem[294]=24'hE277C8; mem[295]=24'hE1B7C5;
        mem[296]=24'hE0F7C2; mem[297]=24'hE027BF; mem[298]=24'hDF67BB; mem[299]=24'hDEA7B8; mem[300]=24'hDDE7B5; mem[301]=24'hDD27B1; mem[302]=24'hDC67AE; mem[303]=24'hDBA7AA;
        mem[304]=24'hDAE7A7; mem[305]=24'hDA27A3; mem[306]=24'hD9679F; mem[307]=24'hD8A79C; mem[308]=24'hD7E798; mem[309]=24'hD72794; mem[310]=24'hD66790; mem[311]=24'hD5A78C;
        mem[312]=24'hD4E787; mem[313]=24'hD43783; mem[314]=24'hD3777F; mem[315]=24'hD2B77A; mem[316]=24'hD1F776; mem[317]=24'hD14771; mem[318]=24'hD0876D; mem[319]=24'hCFC768;
        mem[320]=24'hCF1763; mem[321]=24'hCE575E; mem[322]=24'hCD9759; mem[323]=24'hCCE754; mem[324]=24'hCC274F; mem[325]=24'hCB774A; mem[326]=24'hCAC745; mem[327]=24'hCA0740;
        mem[328]=24'hC9573A; mem[329]=24'hC89735; mem[330]=24'hC7E730; mem[331]=24'hC7372A; mem[332]=24'hC68724; mem[333]=24'hC5C71F; mem[334]=24'hC51719; mem[335]=24'hC46713;
        mem[336]=24'hC3B70D; mem[337]=24'hC30707; mem[338]=24'hC25701; mem[339]=24'hC1A6FB; mem[340]=24'hC0F6F5; mem[341]=24'hC046EF; mem[342]=24'hBF96E9; mem[343]=24'hBEE6E2;
        mem[344]=24'hBE46DC; mem[345]=24'hBD96D5; mem[346]=24'hBCE6CF; mem[347]=24'hBC36C8; mem[348]=24'hBB96C1; mem[349]=24'hBAE6BB; mem[350]=24'hBA46B4; mem[351]=24'hB996AD;
        mem[352]=24'hB8F6A6; mem[353]=24'hB8469F; mem[354]=24'hB7A698; mem[355]=24'hB70691; mem[356]=24'hB6568A; mem[357]=24'hB5B682; mem[358]=24'hB5167B; mem[359]=24'hB47674;
        mem[360]=24'hB3D66C; mem[361]=24'hB33665; mem[362]=24'hB2965D; mem[363]=24'hB1F655; mem[364]=24'hB1564E; mem[365]=24'hB0B646; mem[366]=24'hB0163E; mem[367]=24'hAF7636;
        mem[368]=24'hAED62E; mem[369]=24'hAE4626; mem[370]=24'hADA61E; mem[371]=24'hAD0616; mem[372]=24'hAC760E; mem[373]=24'hABD606; mem[374]=24'hAB45FD; mem[375]=24'hAAB5F5;
        mem[376]=24'hAA15ED; mem[377]=24'hA985E4; mem[378]=24'hA8F5DC; mem[379]=24'hA865D3; mem[380]=24'hA7D5CB; mem[381]=24'hA735C2; mem[382]=24'hA6A5B9; mem[383]=24'hA615B0;
        mem[384]=24'hA595A7; mem[385]=24'hA5059F; mem[386]=24'hA47596; mem[387]=24'hA3E58D; mem[388]=24'hA35583; mem[389]=24'hA2D57A; mem[390]=24'hA24571; mem[391]=24'hA1C568;
        mem[392]=24'hA1355F; mem[393]=24'hA0B555; mem[394]=24'hA0354C; mem[395]=24'h9FA543; mem[396]=24'h9F2539; mem[397]=24'h9EA530; mem[398]=24'h9E2526; mem[399]=24'h9DA51C;
        mem[400]=24'h9D2513; mem[401]=24'h9CA509; mem[402]=24'h9C24FF; mem[403]=24'h9BA4F5; mem[404]=24'h9B24EB; mem[405]=24'h9AB4E1; mem[406]=24'h9A34D7; mem[407]=24'h99B4CD;
        mem[408]=24'h9944C3; mem[409]=24'h98C4B9; mem[410]=24'h9854AF; mem[411]=24'h97E4A5; mem[412]=24'h97649B; mem[413]=24'h96F490; mem[414]=24'h968486; mem[415]=24'h96147C;
        mem[416]=24'h95A471; mem[417]=24'h953467; mem[418]=24'h94C45C; mem[419]=24'h945452; mem[420]=24'h93F447; mem[421]=24'h93843D; mem[422]=24'h931432; mem[423]=24'h92B427;
        mem[424]=24'h92441C; mem[425]=24'h91E412; mem[426]=24'h917407; mem[427]=24'h9113FC; mem[428]=24'h90B3F1; mem[429]=24'h9053E6; mem[430]=24'h8FF3DB; mem[431]=24'h8F93D0;
        mem[432]=24'h8F33C5; mem[433]=24'h8ED3BA; mem[434]=24'h8E73AF; mem[435]=24'h8E13A4; mem[436]=24'h8DC398; mem[437]=24'h8D638D; mem[438]=24'h8D0382; mem[439]=24'h8CB377;
        mem[440]=24'h8C636B; mem[441]=24'h8C0360; mem[442]=24'h8BB354; mem[443]=24'h8B6349; mem[444]=24'h8B133E; mem[445]=24'h8AC332; mem[446]=24'h8A7327; mem[447]=24'h8A231B;
        mem[448]=24'h89D30F; mem[449]=24'h898304; mem[450]=24'h8932F8; mem[451]=24'h88F2EC; mem[452]=24'h88A2E1; mem[453]=24'h8862D5; mem[454]=24'h8812C9; mem[455]=24'h87D2BD;
        mem[456]=24'h8792B2; mem[457]=24'h8742A6; mem[458]=24'h87029A; mem[459]=24'h86C28E; mem[460]=24'h868282; mem[461]=24'h864276; mem[462]=24'h86126A; mem[463]=24'h85D25E;
        mem[464]=24'h859252; mem[465]=24'h856246; mem[466]=24'h85223A; mem[467]=24'h84F22E; mem[468]=24'h84B222; mem[469]=24'h848216; mem[470]=24'h84520A; mem[471]=24'h8411FE;
        mem[472]=24'h83E1F1; mem[473]=24'h83B1E5; mem[474]=24'h8381D9; mem[475]=24'h8361CD; mem[476]=24'h8331C1; mem[477]=24'h8301B4; mem[478]=24'h82D1A8; mem[479]=24'h82B19C;
        mem[480]=24'h82818F; mem[481]=24'h826183; mem[482]=24'h824177; mem[483]=24'h82116A; mem[484]=24'h81F15E; mem[485]=24'h81D152; mem[486]=24'h81B145; mem[487]=24'h819139;
        mem[488]=24'h81712C; mem[489]=24'h815120; mem[490]=24'h814113; mem[491]=24'h812107; mem[492]=24'h8100FB; mem[493]=24'h80F0EE; mem[494]=24'h80D0E2; mem[495]=24'h80C0D5;
        mem[496]=24'h80B0C9; mem[497]=24'h80A0BC; mem[498]=24'h8090B0; mem[499]=24'h8080A3; mem[500]=24'h807097; mem[501]=24'h80608A; mem[502]=24'h80507E; mem[503]=24'h804071;
        mem[504]=24'h803064; mem[505]=24'h803058; mem[506]=24'h80204B; mem[507]=24'h80203F; mem[508]=24'h802032; mem[509]=24'h801026; mem[510]=24'h801019; mem[511]=24'h80100D;
        mem[512]=24'h801000; mem[513]=24'h801FF3; mem[514]=24'h801FE7; mem[515]=24'h801FDA; mem[516]=24'h802FCE; mem[517]=24'h802FC1; mem[518]=24'h802FB5; mem[519]=24'h803FA8;
        mem[520]=24'h803F9C; mem[521]=24'h804F8F; mem[522]=24'h805F82; mem[523]=24'h806F76; mem[524]=24'h807F69; mem[525]=24'h808F5D; mem[526]=24'h809F50; mem[527]=24'h80AF44;
        mem[528]=24'h80BF37; mem[529]=24'h80CF2B; mem[530]=24'h80DF1E; mem[531]=24'h80FF12; mem[532]=24'h810F05; mem[533]=24'h812EF9; mem[534]=24'h814EED; mem[535]=24'h815EE0;
        mem[536]=24'h817ED4; mem[537]=24'h819EC7; mem[538]=24'h81BEBB; mem[539]=24'h81DEAE; mem[540]=24'h81FEA2; mem[541]=24'h821E96; mem[542]=24'h824E89; mem[543]=24'h826E7D;
        mem[544]=24'h828E71; mem[545]=24'h82BE64; mem[546]=24'h82DE58; mem[547]=24'h830E4C; mem[548]=24'h833E3F; mem[549]=24'h836E33; mem[550]=24'h838E27; mem[551]=24'h83BE1B;
        mem[552]=24'h83EE0F; mem[553]=24'h841E02; mem[554]=24'h845DF6; mem[555]=24'h848DEA; mem[556]=24'h84BDDE; mem[557]=24'h84FDD2; mem[558]=24'h852DC6; mem[559]=24'h856DBA;
        mem[560]=24'h859DAE; mem[561]=24'h85DDA2; mem[562]=24'h861D96; mem[563]=24'h864D8A; mem[564]=24'h868D7E; mem[565]=24'h86CD72; mem[566]=24'h870D66; mem[567]=24'h874D5A;
        mem[568]=24'h879D4E; mem[569]=24'h87DD43; mem[570]=24'h881D37; mem[571]=24'h886D2B; mem[572]=24'h88AD1F; mem[573]=24'h88FD14; mem[574]=24'h893D08; mem[575]=24'h898CFC;
        mem[576]=24'h89DCF1; mem[577]=24'h8A2CE5; mem[578]=24'h8A7CD9; mem[579]=24'h8ACCCE; mem[580]=24'h8B1CC2; mem[581]=24'h8B6CB7; mem[582]=24'h8BBCAC; mem[583]=24'h8C0CA0;
        mem[584]=24'h8C6C95; mem[585]=24'h8CBC89; mem[586]=24'h8D0C7E; mem[587]=24'h8D6C73; mem[588]=24'h8DCC68; mem[589]=24'h8E1C5C; mem[590]=24'h8E7C51; mem[591]=24'h8EDC46;
        mem[592]=24'h8F3C3B; mem[593]=24'h8F9C30; mem[594]=24'h8FFC25; mem[595]=24'h905C1A; mem[596]=24'h90BC0F; mem[597]=24'h911C04; mem[598]=24'h917BF9; mem[599]=24'h91EBEE;
        mem[600]=24'h924BE4; mem[601]=24'h92BBD9; mem[602]=24'h931BCE; mem[603]=24'h938BC3; mem[604]=24'h93FBB9; mem[605]=24'h945BAE; mem[606]=24'h94CBA4; mem[607]=24'h953B99;
        mem[608]=24'h95AB8F; mem[609]=24'h961B84; mem[610]=24'h968B7A; mem[611]=24'h96FB70; mem[612]=24'h976B65; mem[613]=24'h97EB5B; mem[614]=24'h985B51; mem[615]=24'h98CB47;
        mem[616]=24'h994B3D; mem[617]=24'h99BB33; mem[618]=24'h9A3B29; mem[619]=24'h9ABB1F; mem[620]=24'h9B2B15; mem[621]=24'h9BAB0B; mem[622]=24'h9C2B01; mem[623]=24'h9CAAF7;
        mem[624]=24'h9D2AED; mem[625]=24'h9DAAE4; mem[626]=24'h9E2ADA; mem[627]=24'h9EAAD0; mem[628]=24'h9F2AC7; mem[629]=24'h9FAABD; mem[630]=24'hA03AB4; mem[631]=24'hA0BAAB;
        mem[632]=24'hA13AA1; mem[633]=24'hA1CA98; mem[634]=24'hA24A8F; mem[635]=24'hA2DA86; mem[636]=24'hA35A7D; mem[637]=24'hA3EA73; mem[638]=24'hA47A6A; mem[639]=24'hA50A61;
        mem[640]=24'hA59A59; mem[641]=24'hA61A50; mem[642]=24'hA6AA47; mem[643]=24'hA73A3E; mem[644]=24'hA7DA35; mem[645]=24'hA86A2D; mem[646]=24'hA8FA24; mem[647]=24'hA98A1C;
        mem[648]=24'hAA1A13; mem[649]=24'hAABA0B; mem[650]=24'hAB4A03; mem[651]=24'hABD9FA; mem[652]=24'hAC79F2; mem[653]=24'hAD09EA; mem[654]=24'hADA9E2; mem[655]=24'hAE49DA;
        mem[656]=24'hAED9D2; mem[657]=24'hAF79CA; mem[658]=24'hB019C2; mem[659]=24'hB0B9BA; mem[660]=24'hB159B2; mem[661]=24'hB1F9AB; mem[662]=24'hB299A3; mem[663]=24'hB3399B;
        mem[664]=24'hB3D994; mem[665]=24'hB4798C; mem[666]=24'hB51985; mem[667]=24'hB5B97E; mem[668]=24'hB65976; mem[669]=24'hB7096F; mem[670]=24'hB7A968; mem[671]=24'hB84961;
        mem[672]=24'hB8F95A; mem[673]=24'hB99953; mem[674]=24'hBA494C; mem[675]=24'hBAE945; mem[676]=24'hBB993F; mem[677]=24'hBC3938; mem[678]=24'hBCE931; mem[679]=24'hBD992B;
        mem[680]=24'hBE4924; mem[681]=24'hBEE91E; mem[682]=24'hBF9917; mem[683]=24'hC04911; mem[684]=24'hC0F90B; mem[685]=24'hC1A905; mem[686]=24'hC258FF; mem[687]=24'hC308F9;
        mem[688]=24'hC3B8F3; mem[689]=24'hC468ED; mem[690]=24'hC518E7; mem[691]=24'hC5C8E1; mem[692]=24'hC688DC; mem[693]=24'hC738D6; mem[694]=24'hC7E8D0; mem[695]=24'hC898CB;
        mem[696]=24'hC958C6; mem[697]=24'hCA08C0; mem[698]=24'hCAC8BB; mem[699]=24'hCB78B6; mem[700]=24'hCC28B1; mem[701]=24'hCCE8AC; mem[702]=24'hCD98A7; mem[703]=24'hCE58A2;
        mem[704]=24'hCF189D; mem[705]=24'hCFC898; mem[706]=24'hD08893; mem[707]=24'hD1488F; mem[708]=24'hD1F88A; mem[709]=24'hD2B886; mem[710]=24'hD37881; mem[711]=24'hD4387D;
        mem[712]=24'hD4E879; mem[713]=24'hD5A874; mem[714]=24'hD66870; mem[715]=24'hD7286C; mem[716]=24'hD7E868; mem[717]=24'hD8A864; mem[718]=24'hD96861; mem[719]=24'hDA285D;
        mem[720]=24'hDAE859; mem[721]=24'hDBA856; mem[722]=24'hDC6852; mem[723]=24'hDD284F; mem[724]=24'hDDE84B; mem[725]=24'hDEA848; mem[726]=24'hDF6845; mem[727]=24'hE02841;
        mem[728]=24'hE0F83E; mem[729]=24'hE1B83B; mem[730]=24'hE27838; mem[731]=24'hE33836; mem[732]=24'hE3F833; mem[733]=24'hE4C830; mem[734]=24'hE5882D; mem[735]=24'hE6482B;
        mem[736]=24'hE71828; mem[737]=24'hE7D826; mem[738]=24'hE89824; mem[739]=24'hE96821; mem[740]=24'hEA281F; mem[741]=24'hEAE81D; mem[742]=24'hEBB81B; mem[743]=24'hEC7819;
        mem[744]=24'hED4817; mem[745]=24'hEE0815; mem[746]=24'hEED814; mem[747]=24'hEF9812; mem[748]=24'hF05810; mem[749]=24'hF1280F; mem[750]=24'hF1E80D; mem[751]=24'hF2B80C;
        mem[752]=24'hF3780B; mem[753]=24'hF4480A; mem[754]=24'hF50809; mem[755]=24'hF5D808; mem[756]=24'hF69807; mem[757]=24'hF76806; mem[758]=24'hF82805; mem[759]=24'hF8F804;
        mem[760]=24'hF9C803; mem[761]=24'hFA8803; mem[762]=24'hFB5802; mem[763]=24'hFC1802; mem[764]=24'hFCE802; mem[765]=24'hFDA801; mem[766]=24'hFE7801; mem[767]=24'hFF3801;
        mem[768]=24'h000801; mem[769]=24'h00D801; mem[770]=24'h019801; mem[771]=24'h026801; mem[772]=24'h032802; mem[773]=24'h03F802; mem[774]=24'h04B802; mem[775]=24'h058803;
        mem[776]=24'h064803; mem[777]=24'h071804; mem[778]=24'h07E805; mem[779]=24'h08A806; mem[780]=24'h097807; mem[781]=24'h0A3808; mem[782]=24'h0B0809; mem[783]=24'h0BC80A;
        mem[784]=24'h0C980B; mem[785]=24'h0D580C; mem[786]=24'h0E280D; mem[787]=24'h0EE80F; mem[788]=24'h0FB810; mem[789]=24'h107812; mem[790]=24'h113814; mem[791]=24'h120815;
        mem[792]=24'h12C817; mem[793]=24'h139819; mem[794]=24'h14581B; mem[795]=24'h15281D; mem[796]=24'h15E81F; mem[797]=24'h16A821; mem[798]=24'h177824; mem[799]=24'h183826;
        mem[800]=24'h18F828; mem[801]=24'h19C82B; mem[802]=24'h1A882D; mem[803]=24'h1B4830; mem[804]=24'h1C1833; mem[805]=24'h1CD836; mem[806]=24'h1D9838; mem[807]=24'h1E583B;
        mem[808]=24'h1F183E; mem[809]=24'h1FE841; mem[810]=24'h20A845; mem[811]=24'h216848; mem[812]=24'h22284B; mem[813]=24'h22E84F; mem[814]=24'h23A852; mem[815]=24'h246856;
        mem[816]=24'h252859; mem[817]=24'h25E85D; mem[818]=24'h26A861; mem[819]=24'h276864; mem[820]=24'h282868; mem[821]=24'h28E86C; mem[822]=24'h29A870; mem[823]=24'h2A6874;
        mem[824]=24'h2B2879; mem[825]=24'h2BD87D; mem[826]=24'h2C9881; mem[827]=24'h2D5886; mem[828]=24'h2E188A; mem[829]=24'h2EC88F; mem[830]=24'h2F8893; mem[831]=24'h304898;
        mem[832]=24'h30F89D; mem[833]=24'h31B8A2; mem[834]=24'h3278A7; mem[835]=24'h3328AC; mem[836]=24'h33E8B1; mem[837]=24'h3498B6; mem[838]=24'h3548BB; mem[839]=24'h3608C0;
        mem[840]=24'h36B8C6; mem[841]=24'h3778CB; mem[842]=24'h3828D0; mem[843]=24'h38D8D6; mem[844]=24'h3988DC; mem[845]=24'h3A48E1; mem[846]=24'h3AF8E7; mem[847]=24'h3BA8ED;
        mem[848]=24'h3C58F3; mem[849]=24'h3D08F9; mem[850]=24'h3DB8FF; mem[851]=24'h3E6905; mem[852]=24'h3F190B; mem[853]=24'h3FC911; mem[854]=24'h407917; mem[855]=24'h41291E;
        mem[856]=24'h41C924; mem[857]=24'h42792B; mem[858]=24'h432931; mem[859]=24'h43D938; mem[860]=24'h44793F; mem[861]=24'h452945; mem[862]=24'h45C94C; mem[863]=24'h467953;
        mem[864]=24'h47195A; mem[865]=24'h47C961; mem[866]=24'h486968; mem[867]=24'h49096F; mem[868]=24'h49B976; mem[869]=24'h4A597E; mem[870]=24'h4AF985; mem[871]=24'h4B998C;
        mem[872]=24'h4C3994; mem[873]=24'h4CD99B; mem[874]=24'h4D79A3; mem[875]=24'h4E19AB; mem[876]=24'h4EB9B2; mem[877]=24'h4F59BA; mem[878]=24'h4FF9C2; mem[879]=24'h5099CA;
        mem[880]=24'h5139D2; mem[881]=24'h51C9DA; mem[882]=24'h5269E2; mem[883]=24'h5309EA; mem[884]=24'h5399F2; mem[885]=24'h5439FA; mem[886]=24'h54CA03; mem[887]=24'h555A0B;
        mem[888]=24'h55FA13; mem[889]=24'h568A1C; mem[890]=24'h571A24; mem[891]=24'h57AA2D; mem[892]=24'h583A35; mem[893]=24'h58DA3E; mem[894]=24'h596A47; mem[895]=24'h59FA50;
        mem[896]=24'h5A7A59; mem[897]=24'h5B0A61; mem[898]=24'h5B9A6A; mem[899]=24'h5C2A73; mem[900]=24'h5CBA7D; mem[901]=24'h5D3A86; mem[902]=24'h5DCA8F; mem[903]=24'h5E4A98;
        mem[904]=24'h5EDAA1; mem[905]=24'h5F5AAB; mem[906]=24'h5FDAB4; mem[907]=24'h606ABD; mem[908]=24'h60EAC7; mem[909]=24'h616AD0; mem[910]=24'h61EADA; mem[911]=24'h626AE4;
        mem[912]=24'h62EAED; mem[913]=24'h636AF7; mem[914]=24'h63EB01; mem[915]=24'h646B0B; mem[916]=24'h64EB15; mem[917]=24'h655B1F; mem[918]=24'h65DB29; mem[919]=24'h665B33;
        mem[920]=24'h66CB3D; mem[921]=24'h674B47; mem[922]=24'h67BB51; mem[923]=24'h682B5B; mem[924]=24'h68AB65; mem[925]=24'h691B70; mem[926]=24'h698B7A; mem[927]=24'h69FB84;
        mem[928]=24'h6A6B8F; mem[929]=24'h6ADB99; mem[930]=24'h6B4BA4; mem[931]=24'h6BBBAE; mem[932]=24'h6C1BB9; mem[933]=24'h6C8BC3; mem[934]=24'h6CFBCE; mem[935]=24'h6D5BD9;
        mem[936]=24'h6DCBE4; mem[937]=24'h6E2BEE; mem[938]=24'h6E9BF9; mem[939]=24'h6EFC04; mem[940]=24'h6F5C0F; mem[941]=24'h6FBC1A; mem[942]=24'h701C25; mem[943]=24'h707C30;
        mem[944]=24'h70DC3B; mem[945]=24'h713C46; mem[946]=24'h719C51; mem[947]=24'h71FC5C; mem[948]=24'h724C68; mem[949]=24'h72AC73; mem[950]=24'h730C7E; mem[951]=24'h735C89;
        mem[952]=24'h73AC95; mem[953]=24'h740CA0; mem[954]=24'h745CAC; mem[955]=24'h74ACB7; mem[956]=24'h74FCC2; mem[957]=24'h754CCE; mem[958]=24'h759CD9; mem[959]=24'h75ECE5;
        mem[960]=24'h763CF1; mem[961]=24'h768CFC; mem[962]=24'h76DD08; mem[963]=24'h771D14; mem[964]=24'h776D1F; mem[965]=24'h77AD2B; mem[966]=24'h77FD37; mem[967]=24'h783D43;
        mem[968]=24'h787D4E; mem[969]=24'h78CD5A; mem[970]=24'h790D66; mem[971]=24'h794D72; mem[972]=24'h798D7E; mem[973]=24'h79CD8A; mem[974]=24'h79FD96; mem[975]=24'h7A3DA2;
        mem[976]=24'h7A7DAE; mem[977]=24'h7AADBA; mem[978]=24'h7AEDC6; mem[979]=24'h7B1DD2; mem[980]=24'h7B5DDE; mem[981]=24'h7B8DEA; mem[982]=24'h7BBDF6; mem[983]=24'h7BFE02;
        mem[984]=24'h7C2E0F; mem[985]=24'h7C5E1B; mem[986]=24'h7C8E27; mem[987]=24'h7CAE33; mem[988]=24'h7CDE3F; mem[989]=24'h7D0E4C; mem[990]=24'h7D3E58; mem[991]=24'h7D5E64;
        mem[992]=24'h7D8E71; mem[993]=24'h7DAE7D; mem[994]=24'h7DCE89; mem[995]=24'h7DFE96; mem[996]=24'h7E1EA2; mem[997]=24'h7E3EAE; mem[998]=24'h7E5EBB; mem[999]=24'h7E7EC7;
        mem[1000]=24'h7E9ED4; mem[1001]=24'h7EBEE0; mem[1002]=24'h7ECEED; mem[1003]=24'h7EEEF9; mem[1004]=24'h7F0F05; mem[1005]=24'h7F1F12; mem[1006]=24'h7F3F1E; mem[1007]=24'h7F4F2B;
        mem[1008]=24'h7F5F37; mem[1009]=24'h7F6F44; mem[1010]=24'h7F7F50; mem[1011]=24'h7F8F5D; mem[1012]=24'h7F9F69; mem[1013]=24'h7FAF76; mem[1014]=24'h7FBF82; mem[1015]=24'h7FCF8F;
        mem[1016]=24'h7FDF9C; mem[1017]=24'h7FDFA8; mem[1018]=24'h7FEFB5; mem[1019]=24'h7FEFC1; mem[1020]=24'h7FEFCE; mem[1021]=24'h7FFFDA; mem[1022]=24'h7FFFE7; mem[1023]=24'h7FFFF3;
    end

    always @(posedge clk) begin
        o_sin <= mem[addr][11:0];
        o_cos <= mem[addr][23:12];
    end
endmodule
