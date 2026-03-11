# Chuyển từ AWS sang DigitalOcean – Lỗi do khác biệt môi trường và quyền hạn

Tài liệu này tập trung vào các lỗi gây ra bởi **sự khác biệt giữa hai nền tảng cloud** (chính sách, quyền, cách quản lý DB/Kubernetes), khi chuyển Moodle từ **AWS (EKS + RDS)** sang **DigitalOcean (DOKS + Managed PostgreSQL)**.

---

## 1. Permission denied for schema public (PostgreSQL)

### Triệu chứng

- Moodle cài đặt DB thất bại tại `install_database.php`, lỗi **ddlexecuteerror** khi COMMIT / tạo bảng.
- Thử `CREATE TABLE` với user ứng dụng (`moodleuser`):  
  `ERROR: permission denied for schema public`

### Nguyên nhân (khác biệt cloud)

- **AWS RDS:** User do bạn tạo (qua Terraform/parameter) thường được cấp quyền đầy đủ trên database và schema `public` (hoặc bạn là owner).
- **DigitalOcean Managed PostgreSQL:** User tạo qua API (ví dụ `digitalocean_database_user`) **mặc định không** có quyền tạo đối tượng trong schema `public`. Schema `public` thuộc quyền quản trị (user `doadmin`), nên app user cần được cấp rõ ràng `USAGE` + `CREATE` (hoặc `ALL`) trên schema `public`.

### Cách xử lý

- Kết nối với user **doadmin** (mật khẩu từ Control Panel hoặc DO API nếu token có scope `database:view_credentials`) và chạy:
  ```sql
  GRANT ALL ON SCHEMA public TO moodleuser;
  GRANT CREATE ON SCHEMA public TO moodleuser;
  ```
- Script `do_full_setup.sh` tự động hóa bước này (Step 2.5): lấy doadmin password qua API hoặc từ `.env`, chạy Job trong cluster để thực thi GRANT.

**Tham khảo:** [DigitalOcean – Fix "permission denied for schema public"](https://docs.digitalocean.com/support/how-do-i-fix-a-permission-denied-for-schema-public-error-in-postgresql/).

---

## 2. Cấu hình kết nối PostgreSQL (SSL, port, timeout)

### Triệu chứng

- Trên AWS (RDS) Moodle chạy bình thường với `config.php` đơn giản (host, port mặc định, không bắt buộc SSL).
- Trên DO Managed DB: lỗi kết nối, timeout hoặc SSL nếu thiếu tham số.

### Nguyên nhân (khác biệt cloud)

- **AWS RDS (trong VPC):** Có thể dùng kết nối nội bộ, port mặc định 5432, SSL không bắt buộc tùy cấu hình.
- **DigitalOcean Managed PostgreSQL:** Kết nối từ bên ngoài (kể cả từ cluster) thường **bắt buộc SSL** (`sslmode=require`). Port và host phải khai báo rõ; thiếu timeout dễ gây treo khi mạng/DB chậm.

### Cách xử lý

- Trong `config.php` cho DO, bổ sung trong `dboptions`:
  - `dbport` = port từ Terraform output (`db_port`).
  - `sslmode` = `'require'`.
  - `connect_timeout` = 30.
- Script AWS giữ cấu hình phù hợp RDS (không bắt buộc SSL theo cùng cách).

---

## 3. Mật khẩu user database (mô hình quản lý khác nhau)

### Triệu chứng

- Trên AWS: mật khẩu RDS do bạn đặt trong Terraform hoặc biến.
- Chuyển sang DO: khai báo resource user với `password = var.xxx` sẽ không khớp với API DO.

### Nguyên nhân (khác biệt cloud)

- **AWS RDS:** Bạn tạo user và **tự đặt** mật khẩu (parameter, biến Terraform, .env).
- **DigitalOcean Managed Database:** Resource `digitalocean_database_user` **không** có attribute `password`. Mật khẩu do **DigitalOcean tự sinh** khi tạo user và **chỉ** đọc được qua **data source** `digitalocean_database_user` (attribute `password`). Không có cách “đặt sẵn” password qua Terraform.

### Cách xử lý

- Terraform DO:
  - Tạo user bằng `digitalocean_database_user.moodle` (không truyền password).
  - Thêm `data "digitalocean_database_user" "moodle"` trỏ tới user vừa tạo.
  - Output `db_password` = `data.digitalocean_database_user.moodle.password`.
- Script đọc `db_password` từ Terraform output; không dùng biến `.env` cho mật khẩu user ứng dụng trên DO.

---

## 4. Kubeconfig (format và cách cấp)

### Triệu chứng

- Script dùng `terraform output -raw kubeconfig` nhưng trên DO output có thể là object (nested) → lỗi khi ghi file hoặc dùng với `KUBECONFIG`.

### Nguyên nhân (khác biệt cloud)

- **AWS EKS:** `aws eks update-kubeconfig` ghi trực tiếp vào `~/.kube/config`, dùng profile/context; không cần Terraform output kubeconfig.
- **DigitalOcean DOKS:** Terraform trả về thông tin cluster trong object; chuỗi dùng được cho `kubectl` nằm ở `kube_config[0].raw_config`, không phải toàn bộ object. Nếu output trỏ sai attribute thì không dùng được.

### Cách xử lý

- Terraform DO:
  ```hcl
  output "kubeconfig" {
    value   = digitalocean_kubernetes_cluster.moodle_cluster.kube_config[0].raw_config
    sensitive = true
  }
  ```
- Script dùng `terraform output -raw kubeconfig`, ghi ra file rồi `export KUBECONFIG=...` để mọi lệnh `kubectl` trỏ đúng cluster DO.

---

## Tóm tắt

| Vấn đề | Nguyên nhân (khác biệt cloud) | Hướng xử lý |
|--------|------------------------------|-------------|
| Permission denied schema public | DO Managed PG không cấp CREATE trên `public` cho app user; RDS thường cho phép | GRANT với doadmin; Step 2.5 trong script |
| Kết nối DB / SSL / timeout | DO bắt buộc SSL, cần port/timeout rõ; RDS trong VPC linh hoạt hơn | config.php DO: `dbport`, `sslmode=require`, `connect_timeout` |
| Mật khẩu DB | AWS: tự đặt. DO: API không cho đặt, password tự sinh, chỉ đọc qua data source | Terraform: data source `digitalocean_database_user`, output `db_password` |
| Kubeconfig | EKS: aws cli update-kubeconfig. DOKS: Terraform trả object, chuỗi dùng được ở `raw_config` | Output `kube_config[0].raw_config`, script ghi file và export KUBECONFIG |
