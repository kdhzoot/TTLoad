# TTLoad (ttload benchmark) Migration & Logic Analysis

이 문서는 `S3-LOAD` 프로젝트에서 `TTLoad`로 포팅된 `ttload` 벤치마크의 동작 원리와 이를 위해 수정된 RocksDB 코어 로직을 설명합니다.

---

## 1. 개요 (Overview)
`ttload`는 외부 CSV 파일에 정의된 통계 정보(Key 범위, SST 개수, 데이터 분포 등)를 바탕으로 실제 RocksDB 데이터베이스를 재구성하는 벤치마크입니다. 일반적인 `fillrandom`과 달리, 특정 시점의 데이터 레이아웃(Level별 SST 분포)을 물리적으로 복제하는 데 특화되어 있습니다.

## 2. 주요 동작 과정 (Workflow)

### A. CSV 파싱 및 통계 로드 (`LevelStatsFromCsv`)
- 사용자가 지정한 `--csv_path` 파일을 읽어 각 레벨(L1~L6)의 SST 파일 개수, 최소/최대 키, 데이터 밀도, Gap 분포 등을 `LevelStats` 구조체로 로드합니다.

### B. 병렬 SST 생성 및 인제스트 (`S3DoWriteSST`)
- **Level-wise 병렬화**: 각 레벨별로 독립적인 스레드 풀 작업을 생성합니다.
- **레벨 간 의존성**: 하위 레벨(예: L2)의 인제스트가 시작되기 전까지 상위 레벨(예: L1)의 생성이 완료되도록 `condition_variable`을 사용하여 순서를 보장합니다.
- **SST 파일 직접 쓰기**: `SstFileWriter`를 사용하여 DB 디렉토리 내에 직접 `.sst` 파일을 생성합니다. 이때 파일 이름은 RocksDB가 나중에 부여할 번호를 미리 예측하여 생성합니다.

### C. 코어 레벨 인제스트 (Ingestion)
- 생성된 파일 경로 리스트를 `IngestExternalFile` API에 전달합니다. 이때 `move_files = false` 옵션을 사용하되, 코어 로직 수정을 통해 물리적 복사 단계를 생략합니다.

---

## 3. 핵심 수정 코드 및 기술적 포인트 (Key Modifications)

### 1) 파일명 기반의 파일 번호 유지 (`ExternalSstFileIngestionJob::Prepare`)
RocksDB는 원래 인제스트되는 파일에 새로운 시퀀스 번호를 부여하고 이름을 바꿉니다. `ttload`는 이 과정을 생략하고 우리가 미리 지정한 파일 번호를 그대로 사용해야 합니다.
- **수정 위치**: `db/external_sst_file_ingestion_job.cc`
- **로직**: `TableFileNameToNumber(file_path)`를 호출하여 실제 파일명(예: `000197.sst`)에서 번호(`197`)를 추출하고, 이를 `file_number_to_use`로 확정합니다.

### 2) Zero-Copy Ingestion (Path Matching)
파일이 이미 DB 디렉토리에 정확한 이름으로 존재한다면, RocksDB가 이를 다시 복사(Link/Copy)하지 않도록 강제합니다.
- **수정 위치**: `db/external_sst_file_ingestion_job.cc`
- **로직**:
  ```cpp
  if (path_outside_db == path_inside_db) {
    f.copy_file = false; // 복사 생략
    f.internal_file_path = path_inside_db;
    // 파일 동기화(sync)만 수행하고 즉시 사용
  }
  ```

### 3) 경로 문자열 정합성 문제 해결 (`TableFileName`)
`actual size 0` 에러의 근본 원인이었던 경로 불일치 문제를 해결했습니다.
- **문제**: `--db=test_db/` 처럼 슬래시가 포함된 경우 `test_db//000197.sst`와 같이 경로가 생성되어 내부적으로 `==` 비교가 실패했었습니다.
- **수정 위치**: `file/filename.cc`
- **로직**: `TableFileName` 함수에서 베이스 경로 끝에 슬래시가 있다면 제거하여 `path/file.sst` 형태의 표준 포맷을 보장합니다.

---

## 4. 트러블슈팅 이력 (Lessons Learned)

- **Corruption: Sst file size mismatch (actual size 0)**:
    - RocksDB가 두 경로가 다르다고 판단하면, "외부" 파일을 "내부"로 복사하려 시도합니다.
    - 하지만 실제로는 동일한 파일이므로, 복사 과정(Link)에서 기존 파일이 트런케이트(Truncate)되거나 쓰기 채널 충돌이 발생하여 파일 크기가 0이 되었습니다.
    - **해결**: 경로 생성 함수(`TableFileName`)를 수정하여 문자열 일치(`==`)를 보장함으로써 해결했습니다.

- **File Number Collision**:
    - 여러 스레드가 동시에 `next_file_number`를 업데이트할 때 번호가 겹치지 않도록 `next_file_number_atomic`과 `file_number_mutex`를 사용하여 원자성을 확보했습니다.

---

## 5. 실행 방법 (Example)
```bash
./db_bench \
  --benchmarks=ttload \
  --db=/path/to/rocksdb \
  --csv_path=stats.csv \
  --threads=16 \
  --key_size=16 \
  --value_size=100
```

이 문서는 향후 `ttload`의 커스텀 분포 모델(Fisk, Weibull 등)을 확장하거나 인제스트 성능을 튜닝할 때 가이드라인으로 활용될 수 있습니다.
