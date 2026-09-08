# RG35XX JamVM GitHub Builder v1

Mục tiêu: build JamVM 2.0.0 cho RG35XX hoàn toàn bằng GitHub Actions,
không cần cài Linux/toolchain trên máy Windows.

## Ba bản được build

- A — `--disable-int-caching`
  - Tắt stack caching.
  - Giữ interpreter inlining theo mặc định.

- B — `--disable-int-caching --disable-int-inlining`
  - Tắt cả stack caching và interpreter inlining.

- C — `--disable-int-inlining`
  - Chỉ tắt interpreter inlining.
  - Giữ stack caching theo mặc định.

Mục đích là phân lập crash SIGSEGV 11 của KDTT mà không sửa
FreeJ2ME core/runtime, Smart-Fit, PNG, font, audio hoặc file game.

## Cách sử dụng trên GitHub — không cần gõ lệnh

1. Mở tab **Actions**.
2. Chọn workflow **Build RG35XX JamVM A-B-C**.
3. Bấm **Run workflow**.
4. Khi workflow hoàn tất, mở run đó và kéo xuống phần **Artifacts**.
5. Tải ba artifact:
   - `RG35XX-JamVM-A-no-cache`
   - `RG35XX-JamVM-B-no-cache-no-inline`
   - `RG35XX-JamVM-C-no-inline`

GitHub tải artifact dưới dạng ZIP.

## Thứ tự test khuyến nghị

1. Test A trước.
2. Nếu A vẫn crash, restore hoặc cài thẳng B (backup gốc vẫn được giữ).
3. Test B.
4. Test C để xác nhận độc lập ảnh hưởng của inlining.

## Cách test trên RG35XX

Mỗi artifact có:
- `jamvm` — binary cần test.
- `INSTALL-ON-RG35XX.sh` — tự backup bản gốc rồi cài binary test.
- `RESTORE-ORIGINAL.sh` — khôi phục JamVM gốc.
- thông tin SHA256/readelf/build log.

Chép nguyên thư mục artifact vào thẻ SD.
Chạy `INSTALL-ON-RG35XX.sh`.
Sau đó mở KDTT như bình thường.

Backup gốc cố định:
`/mnt/mmc/CFW/java/bin/jamvm.original-before-github-tests`

Script KHÔNG ghi đè backup này ở các lần test tiếp theo.

## Đọc kết quả

- A chạy ổn:
  stack caching là nghi phạm rất mạnh.
- A crash, B chạy ổn:
  interpreter inlining/rewrite path là nghi phạm rất mạnh.
- C chạy ổn:
  củng cố kết luận inlining gây lỗi.
- A/B/C đều crash:
  cần chuyển sang kiểm tra operand/bytecode/object corruption quanh
  CHECKCAST_QUICK thay vì tiếp tục chỉnh video/Smart-Fit.

## Nguồn và toolchain

JamVM:
- Version 2.0.0
- SHA256 source:
  `76428e96df0ae9dd964c7a7c74c1e9a837e2f312c39e9a357fa8178f7eff80da`

Toolchain image:
- `miyoocfw/toolchain-shared-uclibc:latest`
- cross triple:
  `arm-miyoo-linux-uclibcgnueabi`

Compiler flags nhằm tương thích với binary JamVM đã thu từ máy:
`-mcpu=arm926ej-s -marm -mfloat-abi=soft`

## Lưu ý

Workflow chỉ build artifact. Nó không thể tự sửa máy RG35XX.
Không thay core/runtime/game trong lúc so sánh A/B/C để kết quả có ý nghĩa.
